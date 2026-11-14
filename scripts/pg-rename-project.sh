#!/usr/bin/env bash
#
# 一次性迁移：把 PostgreSQL 从 Casdoor 的旧 project 挪到平台 project，并给 casdoor 角色降权。
#
#   bash scripts/pg-rename-project.sh --dry-run     # 只读：打印现状与计划，不改任何东西
#   bash scripts/pg-rename-project.sh               # 交互确认后执行
#   bash scripts/pg-rename-project.sh --yes         # 无人值守
#
# 迁移内容（见 docs/postgres.md 第六节）：
#   旧：project mybmo-casdoor / 卷 mybmo-casdoor_pgdata / 容器 mybmo-casdoor-postgres-1
#       角色 casdoor 是超级用户，Casdoor 连 host=postgres
#   新：project pandabase / 卷 pandabase_pgdata / 容器 pandabase-postgres
#       角色 pandabase_admin 为唯一超级用户（仅运维），casdoor 降权，Casdoor 连 host=pandabase-postgres
#
# 旧卷与旧容器在第 7 天前一直保留，回滚只需把旧栈 up 起来。

set -euo pipefail
source "$(dirname "$0")/lib.sh"

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --yes | -y) ASSUME_YES=1 ;;
        -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "未知参数：$arg" ;;
    esac
done

OLD_STACK_DIR="${OLD_STACK_DIR:-/opt/mybmo-mcp/deploy/casdoor}"
OLD_PROJECT=mybmo-casdoor
OLD_PGVOL="${OLD_PROJECT}_pgdata"
OLD_CDVOL="${OLD_PROJECT}_casdoor_data"
OLD_PG_CT="${OLD_PROJECT}-postgres-1"

NEW_STACK_DIR="$REPO_ROOT/deploy"
NEW_PGVOL=pandabase_pgdata
NEW_CDVOL=pandabase_casdoor_data
NEW_PG_CT=pandabase-postgres

STAMP="$(date +%F-%H%M%S)"
BK="$REPO_ROOT/backups/rename-$STAMP"

PG_ENV="$NEW_STACK_DIR/postgres/.env"
CD_ENV="$NEW_STACK_DIR/casdoor/.env"
ADMIN_USER="$(env_get "$PG_ENV" POSTGRES_USER || true)"; ADMIN_USER="${ADMIN_USER:-pandabase_admin}"

has_volume() { local all; all="$(docker volume ls --format '{{.Name}}')"; grep -qx "$1" <<< "$all"; }
has_container() { local all; all="$(docker ps -a --format '{{.Names}}')"; grep -qx "$1" <<< "$all"; }
running() { local all; all="$(docker ps --format '{{.Names}}')"; grep -qx "$1" <<< "$all"; }

# 两个 helper 都连 casdoor 库：pg_roles / pg_database 是全局可见的，
# 而 application 等业务表只在 casdoor 库里。
psql_old() { docker exec -i "$OLD_PG_CT" psql -v ON_ERROR_STOP=1 -U casdoor -d casdoor "$@"; }
psql_new() { docker exec -i "$NEW_PG_CT" psql -v ON_ERROR_STOP=1 -U "$1" -d casdoor "${@:2}"; }

# ---------------------------------------------------------------- 0. 预检
log "0/7 预检"

need_cmd docker
docker compose version >/dev/null 2>&1 || die "docker compose v2 不可用"
[[ -f "$OLD_STACK_DIR/docker-compose.yml" ]] || die "找不到旧编排：$OLD_STACK_DIR/docker-compose.yml"
[[ -f "$NEW_STACK_DIR/postgres/docker-compose.yml" ]] || die "找不到新编排：$NEW_STACK_DIR/postgres/docker-compose.yml"
[[ -f "$NEW_STACK_DIR/casdoor/docker-compose.yml" ]] || die "找不到新编排：$NEW_STACK_DIR/casdoor/docker-compose.yml"

has_volume "$OLD_PGVOL" || die "找不到旧数据卷 $OLD_PGVOL，确认是不是已经迁过了"
if has_volume "$NEW_PGVOL"; then
    die "目标卷 $NEW_PGVOL 已存在。若上次迁移中断，先确认它是否可用，必要时 docker volume rm 后重跑"
fi

MISSING=0
for f in "$PG_ENV" "$CD_ENV"; do
    if [[ -f "$f" ]]; then
        info "有 $f"
    else
        warn "缺 $f（迁移前必须准备好：cp .env.example .env 并填值）"
        MISSING=$((MISSING + 1))
    fi
done

DISK_MB="$(df -Pm "$REPO_ROOT" | awk 'NR==2 {print $4}')"
(( DISK_MB >= 1024 )) || die "磁盘只剩 ${DISK_MB}MB，少于 1GB"
info "磁盘可用 ${DISK_MB}MB"

NET_EXISTS=0
docker network ls --format '{{.Name}}' | grep -qx 'pandabase' && NET_EXISTS=1
if (( NET_EXISTS == 0 )); then
    warn "共享网络 pandabase 不存在（迁移前先跑 scripts/bootstrap-network.sh）"
fi

# ---------------------------------------------------------------- 现状
log "现状"
docker ps -a --filter "name=$OLD_PROJECT" --format '   {{.Names}}  {{.Image}}  {{.Status}}'

log "旧库与角色"
psql_old -At -F'|' -c \
    "select datname, pg_get_userbyid(datdba), pg_size_pretty(pg_database_size(datname)) from pg_database order by 1" \
    | sed 's/^/   /'
psql_old -At -F'|' -c \
    "select rolname, rolsuper, rolcreatedb, rolcreaterole from pg_roles where rolname in ('casdoor')" \
    | sed 's/^/   /'

BEFORE_APP="$(psql_old -Atc 'select count(*) from application')"
BEFORE_TABLES="$(psql_old -Atc "select count(*) from information_schema.tables where table_schema='public'")"
info "迁移前：application=$BEFORE_APP  tables=$BEFORE_TABLES"

PGVOL_SIZE="$(docker run --rm -v "$OLD_PGVOL":/v alpine du -sh /v 2>/dev/null | cut -f1)"
info "旧卷 $OLD_PGVOL  $PGVOL_SIZE"

# ---------------------------------------------------------------- 计划
log "计划"
cat <<EOF
   1. 备份：casdoor 库 pg_dump -> $BK，两个旧卷各打一个 tar
   2. 停旧栈（$OLD_PROJECT）：casdoor + postgres
   3. 建新卷 $NEW_PGVOL / $NEW_CDVOL，把旧数据整目录拷过去（同版本 17，直接拷安全）
   4. 起新 project 的 PG（$NEW_PG_CT），校验 PG_VERSION=17
   5. 建 $ADMIN_USER；建 casdoor_app 并转移库与对象属主；封存 bootstrap 角色（NOLOGIN）
   6. 起新 project 的 Casdoor（连 host=$NEW_PG_CT）
   7. 回归：application 行数、表数、discovery、业务 /healthz 与 /mcp 401
   旧卷 $OLD_PGVOL 与旧容器保留，第 7 天再删。回滚 = 起旧栈，3 分钟内。
EOF

if (( DRY_RUN == 1 )); then
    if (( MISSING > 0 )); then
        warn "另有 $MISSING 个 .env 待准备"
    fi
    (( NET_EXISTS == 1 )) || warn "网络 pandabase 待创建"
    log "dry-run 结束：未改动任何东西"
    exit 0
fi

(( MISSING == 0 )) || die "先准备好 $PG_ENV 与 $CD_ENV"
(( NET_EXISTS == 1 )) || die "先跑 scripts/bootstrap-network.sh"

if (( ASSUME_YES == 0 )); then
    [[ -t 0 ]] || die "非交互环境请加 --yes"
    read -r -p "输入 MIGRATE 执行（其他任意键取消）：" answer
    [[ "$answer" == "MIGRATE" ]] || die "已取消，未做任何改动"
fi

# ---------------------------------------------------------------- 1. 备份
log "1/7 备份"
mkdir -p "$BK"; chmod 700 "$BK"
docker exec -i "$OLD_PG_CT" pg_dump -Fc -U casdoor -d casdoor > "$BK/casdoor.dump"
[[ -s "$BK/casdoor.dump" ]] || die "casdoor.dump 为空"
info "casdoor.dump $(du -h "$BK/casdoor.dump" | cut -f1)"

docker run --rm -v "$OLD_PGVOL":/from -v "$BK":/b alpine tar czf /b/pgdata-16to17.tgz -C /from .
docker run --rm -v "$OLD_PGVOL":/v alpine cat /v/PG_VERSION 2>/dev/null | tr -d '\n' | sed 's/^/   pgdata 版本: /'; echo
[[ -s "$BK/pgdata-16to17.tgz" ]] || die "卷备份为空"

if has_volume "$OLD_CDVOL"; then
    docker run --rm -v "$OLD_CDVOL":/from -v "$BK":/b alpine tar czf /b/casdoor_data.tgz -C /from .
    info "casdoor_data.tgz $(du -h "$BK/casdoor_data.tgz" | cut -f1)"
fi

# ---------------------------------------------------------------- 2. 停旧栈
log "2/7 停旧栈"
docker compose -f "$OLD_STACK_DIR/docker-compose.yml" stop

# ---------------------------------------------------------------- 3. 拷卷
log "3/7 建新卷并拷数据"
docker volume create "$NEW_PGVOL" >/dev/null
docker run --rm -v "$NEW_PGVOL":/to -v "$BK":/b alpine sh -c 'cd /to && tar xzf /b/pgdata-16to17.tgz'
VERIFY="$(docker run --rm -v "$NEW_PGVOL":/v alpine cat /v/PG_VERSION 2>/dev/null || true)"
[[ "$VERIFY" == "17" ]] || die "新卷 PG_VERSION=$VERIFY，不是 17；旧卷未动，直接回滚"
info "新卷 $NEW_PGVOL PG_VERSION=$VERIFY"

if [[ -f "$BK/casdoor_data.tgz" ]]; then
    docker volume create "$NEW_CDVOL" >/dev/null
    docker run --rm -v "$NEW_CDVOL":/to -v "$BK":/b alpine sh -c 'cd /to && tar xzf /b/casdoor_data.tgz'
    info "新卷 $NEW_CDVOL 已恢复"
fi

# ---------------------------------------------------------------- 4. 起 PG
log "4/7 起新 PG"
docker compose -f "$NEW_STACK_DIR/postgres/docker-compose.yml" up -d
wait_pg "$NEW_PG_CT" "$ADMIN_USER" || die "新 PG 没起来：docker logs $NEW_PG_CT"
info "PG 已就绪"

# ---------------------------------------------------------------- 5. 角色
log "5/7 角色与属主"
ADMIN_PASS="$(env_get "$PG_ENV" POSTGRES_PASSWORD || true)"
CASDOOR_PASS="$(env_get "$CD_ENV" POSTGRES_PASSWORD || true)"
CASDOOR_ORIGIN="$(env_get "$CD_ENV" CASDOOR_ORIGIN || true)"
[[ -n "$ADMIN_PASS" ]] || die "$PG_ENV 里 POSTGRES_PASSWORD 为空"
[[ -n "$CASDOOR_PASS" ]] || die "$CD_ENV 里 POSTGRES_PASSWORD 为空"

EXISTS="$(psql_new casdoor -Atc "select 1 from pg_roles where rolname = '$ADMIN_USER'" || true)"
if [[ "$EXISTS" == "1" ]]; then
    info "角色 $ADMIN_USER 已存在"
else
    psql_new casdoor -c "CREATE ROLE \"$ADMIN_USER\" LOGIN SUPERUSER CREATEDB CREATEROLE PASSWORD '$ADMIN_PASS'" >/dev/null
    info "已创建 $ADMIN_USER（唯一可登录的超级用户，仅运维使用）"
fi

# initdb 建的 bootstrap 超级用户（原 POSTGRES_USER）**不能降权**：
#   ALTER ROLE ... NOSUPERUSER -> "The bootstrap superuser must have the SUPERUSER attribute"
# 所以改成：新建 casdoor_app 承载服务 + 转移属主 + 封存 bootstrap 角色。
APP_EXISTS="$(psql_new "$ADMIN_USER" -Atc "select 1 from pg_roles where rolname = 'casdoor_app'" || true)"
if [[ "$APP_EXISTS" == "1" ]]; then
    info "角色 casdoor_app 已存在"
else
    psql_new "$ADMIN_USER" -c \
        "CREATE ROLE casdoor_app LOGIN PASSWORD '$CASDOOR_PASS' CONNECTION LIMIT 20" >/dev/null
    info "已创建服务角色 casdoor_app（非超级用户，连接上限 20）"
fi

docker exec -i "$NEW_PG_CT" psql -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d postgres -c \
    'ALTER DATABASE casdoor OWNER TO casdoor_app' >/dev/null
docker exec -i "$NEW_PG_CT" psql -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d casdoor <<'SQL' >/dev/null
DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
        EXECUTE format('ALTER TABLE public.%I OWNER TO casdoor_app', r.tablename);
    END LOOP;
    FOR r IN SELECT sequencename FROM pg_sequences WHERE schemaname = 'public' LOOP
        EXECUTE format('ALTER SEQUENCE public.%I OWNER TO casdoor_app', r.sequencename);
    END LOOP;
    FOR r IN SELECT viewname FROM pg_views WHERE schemaname = 'public' LOOP
        EXECUTE format('ALTER VIEW public.%I OWNER TO casdoor_app', r.viewname);
    END LOOP;
END $$;
SQL
OWNERS="$(docker exec -i "$NEW_PG_CT" psql -U "$ADMIN_USER" -d casdoor -At -F'|' -c \
    "select tableowner, count(*) from pg_tables where schemaname='public' group by 1")"
echo "$OWNERS" | sed 's/^/   属主 /'

# 切换 Casdoor 的连接角色
umask 077
{
    echo "POSTGRES_USER=casdoor_app"
    printf 'POSTGRES_PASSWORD=%s\n' "$CASDOOR_PASS"
    # 2026-11-14 起对外入口是 8443（ADR 0005）；本脚本是 11-08 改名迁移的一次性脚本，
    # 里面的 URL 一律保持当时的样子，不要再拿它当「当前值」抄
    echo "CASDOOR_ORIGIN=${CASDOOR_ORIGIN:-https://auth.pandabase.top}"
} > "$CD_ENV"
chmod 600 "$CD_ENV"
info "Casdoor 连接角色改为 casdoor_app"

# 封存 bootstrap 角色：属性摘不掉，但可以禁止登录
psql_new "$ADMIN_USER" -c 'ALTER ROLE casdoor NOLOGIN' >/dev/null
psql_new "$ADMIN_USER" -c 'ALTER ROLE casdoor CONNECTION LIMIT 0' >/dev/null
info "bootstrap 角色 casdoor 已封存（NOLOGIN + 连接上限 0）"

# ---------------------------------------------------------------- 6. 起 Casdoor
log "6/7 起新 Casdoor"
docker compose -f "$NEW_STACK_DIR/casdoor/docker-compose.yml" up -d --force-recreate casdoor
sleep 5
docker compose -f "$NEW_STACK_DIR/casdoor/docker-compose.yml" ps --format '   {{.Service}}  {{.Image}}  {{.Status}}'

# ---------------------------------------------------------------- 7. 回归
log "7/7 回归"
AFTER_APP="$(psql_new casdoor -Atc 'select count(*) from application')"
AFTER_TABLES="$(psql_new casdoor -Atc "select count(*) from information_schema.tables where table_schema='public'")"
echo "   application: $BEFORE_APP -> $AFTER_APP"
echo "   tables:      $BEFORE_TABLES -> $AFTER_TABLES"
[[ "$BEFORE_APP" == "$AFTER_APP" && "$BEFORE_TABLES" == "$AFTER_TABLES" ]] \
    || die "行数不一致，先别放流量：按下面回滚"

if command -v curl >/dev/null; then
    printf '   discovery: '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 \
        https://auth.pandabase.top/.well-known/openid-configuration
    printf '   业务 /healthz: '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 \
        https://baiduads.pandabase.top/healthz
    printf '   业务 /mcp 无令牌: '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 \
        -X POST -H 'Content-Type: application/json' -d '{}' https://baiduads.pandabase.top/mcp
fi

cat <<EOF

迁移完成。旧卷 $OLD_PGVOL、旧容器与 $OLD_PROJECT 全部保留，未删除。

回滚（3 分钟内）：
  docker compose -f $NEW_STACK_DIR/postgres/docker-compose.yml down
  docker compose -f $NEW_STACK_DIR/casdoor/docker-compose.yml down
  docker compose -f $OLD_STACK_DIR/docker-compose.yml up -d

确认 7 天无异常后再删：
  docker compose -f $OLD_STACK_DIR/docker-compose.yml down
  docker volume rm $OLD_PGVOL $OLD_CDVOL

备份：$BK
EOF
