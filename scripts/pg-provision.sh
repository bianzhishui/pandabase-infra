#!/usr/bin/env bash
#
# 建角色与库。所有 CREATE 都先判断存在性，可重复执行。
#
#   bash scripts/pg-provision.sh --init [--as <现有超级用户>]
#       在**已有数据**的实例上创建 pandabase_admin（从别处迁移过来的场景）。
#       新装机不需要：镜像的 entrypoint 会按 POSTGRES_USER 建好它。
#
#   bash scripts/pg-provision.sh <app>
#       给业务建库与角色，打印一次 DSN。
#
#   bash scripts/pg-provision.sh reader <库名>
#       给运维控制台（DBX）建只读角色 dbx_read：只授这一个库的 SELECT，打印一次 DSN。
#       只读 + 按库授权，不违反 docs/postgres.md 的「角色只拥有自己的库」。
#
# 角色模型见 docs/postgres.md：pandabase_admin 是唯一的超级用户（只给运维用，
# 不注入任何业务容器）；业务角色一律非超级用户，只拥有自己的库。

set -euo pipefail
source "$(dirname "$0")/lib.sh"

PG_CT="${PG_CT:-pandabase-postgres}"
PG_ENV="$REPO_ROOT/deploy/postgres/.env"
ADMIN_USER="$(env_get "$PG_ENV" POSTGRES_USER || true)"; ADMIN_USER="${ADMIN_USER:-pandabase_admin}"
ADMIN_PASS="$(env_get "$PG_ENV" POSTGRES_PASSWORD || true)"

psql_as() {
    local user="$1"; shift
    docker exec -i "$PG_CT" psql -v ON_ERROR_STOP=1 -U "$user" -d postgres "$@"
}

# 连到指定库执行。默认权限是 per-database 的，必须连着目标库才设得上。
psql_db_as() {
    local user="$1" db="$2"; shift 2
    docker exec -i "$PG_CT" psql -v ON_ERROR_STOP=1 -U "$user" -d "$db" "$@"
}

sql_quote() { printf "%s" "${1//\'/\'\'}"; }

role_exists() {
    local name="$1" out
    out="$(psql_as "$ADMIN_USER" -Atc "select 1 from pg_roles where rolname = '$name'")"
    [[ "$out" == "1" ]]
}

db_exists() {
    local name="$1" out
    out="$(psql_as "$ADMIN_USER" -Atc "select 1 from pg_database where datname = '$name'")"
    [[ "$out" == "1" ]]
}

cmd_init() {
    local as="${AS_USER:-casdoor}"
    [[ -n "$ADMIN_PASS" ]] || die "deploy/postgres/.env 里 POSTGRES_PASSWORD 为空"
    docker ps --format '{{.Names}}' | grep -qx "$PG_CT" || die "找不到容器 $PG_CT"

    local out
    out="$(docker exec -i "$PG_CT" psql -v ON_ERROR_STOP=1 -U "$as" -d postgres -Atc \
        "select 1 from pg_roles where rolname = '$ADMIN_USER'")"
    if [[ "$out" == "1" ]]; then
        info "角色 $ADMIN_USER 已存在，跳过"
    else
        docker exec -i "$PG_CT" psql -v ON_ERROR_STOP=1 -U "$as" -d postgres -c \
            "CREATE ROLE \"$ADMIN_USER\" LOGIN SUPERUSER CREATEDB CREATEROLE PASSWORD '$(sql_quote "$ADMIN_PASS")'" >/dev/null
        info "已创建运维角色 $ADMIN_USER（唯一超级用户，仅运维使用）"
    fi
}

cmd_app() {
    local app="$1"
    [[ "$app" =~ ^[a-z][a-z0-9_]{1,30}$ ]] || die "业务名只允许小写字母/数字/下划线，且以字母开头：$app"
    docker ps --format '{{.Names}}' | grep -qx "$PG_CT" || die "找不到容器 $PG_CT"
    [[ -n "$ADMIN_PASS" ]] || die "deploy/postgres/.env 里 POSTGRES_PASSWORD 为空"

    local pass
    pass="$(gen_password)"

    if role_exists "$app"; then
        warn "角色 $app 已存在，不重置口令；如需轮换请手工执行 ALTER ROLE"
        pass="（未变更）"
    else
        psql_as "$ADMIN_USER" -c \
            "CREATE ROLE \"$app\" LOGIN PASSWORD '$(sql_quote "$pass")' CONNECTION LIMIT 20" >/dev/null
        info "已创建角色 $app（LOGIN，无 SUPERUSER/CREATEDB/CREATEROLE，连接上限 20）"
    fi

    if db_exists "$app"; then
        warn "库 $app 已存在，跳过创建"
    else
        psql_as "$ADMIN_USER" -c "CREATE DATABASE \"$app\" OWNER \"$app\"" >/dev/null
        info "已创建库 $app（owner: $app）"
    fi

    psql_as "$ADMIN_USER" -c "REVOKE ALL ON DATABASE \"$app\" FROM PUBLIC" >/dev/null
    psql_as "$ADMIN_USER" -c "GRANT CONNECT, TEMPORARY ON DATABASE \"$app\" TO \"$app\"" >/dev/null

    cat <<EOF

交付给业务方的连接串（口令只在这里打印一次，请立即存入密码管理器）：

  postgresql://$app:$pass@$PG_CT:5432/$app

EOF
}

# 只读角色：给运维控制台用。只授一个库、只授 SELECT，不给 DDL/DML，
# 也不加到第二个库上——需要看别的库就再跑一次，权限面始终是显式的。
cmd_reader() {
    local db="$1"
    local role="dbx_read"

    [[ "$db" =~ ^[a-z][a-z0-9_]{1,30}$ ]] || die "库名只允许小写字母/数字/下划线，且以字母开头：$db"
    docker ps --format '{{.Names}}' | grep -qx "$PG_CT" || die "找不到容器 $PG_CT"
    [[ -n "$ADMIN_PASS" ]] || die "deploy/postgres/.env 里 POSTGRES_PASSWORD 为空"
    db_exists "$db" || die "库 $db 不存在：先建库（bash scripts/pg-provision.sh <app>）"

    local pass owner
    if role_exists "$role"; then
        warn "角色 $role 已存在，不重置口令；如需轮换请手工执行 ALTER ROLE"
        pass=""
    else
        pass="$(gen_password)"
        psql_as "$ADMIN_USER" -c \
            "CREATE ROLE \"$role\" LOGIN PASSWORD '$(sql_quote "$pass")' CONNECTION LIMIT 5" >/dev/null
        info "已创建只读角色 $role（LOGIN，无 SUPERUSER/CREATEDB/CREATEROLE，连接上限 5）"
    fi

    owner="$(psql_as "$ADMIN_USER" -Atc "select pg_get_userbyid(datdba) from pg_database where datname = '$db'")"
    [[ -n "$owner" ]] || die "取不到库 $db 的属主"

    # 幂等重放：库若是手工建的，PUBLIC 可能还留着默认权限
    psql_as "$ADMIN_USER" -c "REVOKE ALL ON DATABASE \"$db\" FROM PUBLIC" >/dev/null
    psql_db_as "$ADMIN_USER" "$db" -c "GRANT CONNECT ON DATABASE \"$db\" TO \"$role\"" >/dev/null
    psql_db_as "$ADMIN_USER" "$db" -c "GRANT USAGE ON SCHEMA public TO \"$role\"" >/dev/null
    psql_db_as "$ADMIN_USER" "$db" -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"$role\"" >/dev/null
    # 让以后新建的表也自动可读；不设这条，第二天新增的表就查不到，报错像权限丢了
    psql_db_as "$ADMIN_USER" "$db" -c \
        "ALTER DEFAULT PRIVILEGES FOR ROLE \"$owner\" IN SCHEMA public GRANT SELECT ON TABLES TO \"$role\"" >/dev/null
    info "已授权 $role 只读库 $db（属主 $owner 的今后新建表一并覆盖）"

    if [[ -z "$pass" ]]; then
        warn "口令未变更，不打印 DSN。轮换：ALTER ROLE $role PASSWORD '<新口令>'"
        return 0
    fi

    cat <<EOF

交付给 DBX 的连接串（口令只在这里打印一次，请立即存入密码管理器）：

  postgresql://$role:$pass@$PG_CT:5432/$db

在 DBX 里新建连接时：
  Host = $PG_CT   Port = 5432   Database = $db   User = $role
  勾上「Read-only connection」，并把「Production protection」一起打开。

EOF
}

case "${1:-}" in
    --init)
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --as) AS_USER="${2:?--as 需要一个现有的超级用户名}"; shift 2 ;;
                *) die "未知参数：$1" ;;
            esac
        done
        cmd_init
        ;;
    reader)
        shift
        [[ $# -eq 1 ]] || die "用法：bash scripts/pg-provision.sh reader <库名>"
        cmd_reader "$1"
        ;;
    "" | -h | --help)
        sed -n '2,17p' "$0"
        exit 0
        ;;
    --*) die "未知参数：$1" ;;
    *) cmd_app "$1" ;;
esac
