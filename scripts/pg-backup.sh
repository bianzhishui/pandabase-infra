#!/usr/bin/env bash
#
# 平台 PG 备份：globals（角色与权限）+ 每个非模板库一份 pg_dump -Fc。
# 库列表是遍历出来的，新增业务自动进备份，不需要改脚本。
#
#   bash scripts/pg-backup.sh                 # 产物在 backups/<YYYY-MM-DD>/
#   OUT=/mnt/backup/pg bash scripts/pg-backup.sh
#
# 注意：备份落在宿主目录，不在容器卷里——卷丢了备份也没了。需要单独拷走。

set -euo pipefail
source "$(dirname "$0")/lib.sh"

PG_CT="${PG_CT:-pandabase-postgres}"
PG_ENV="$REPO_ROOT/deploy/postgres/.env"
ADMIN_USER="$(env_get "$PG_ENV" POSTGRES_USER || true)"; ADMIN_USER="${ADMIN_USER:-pandabase_admin}"
OUT="${OUT:-$REPO_ROOT/backups/$(date +%F)}"

need_cmd docker
docker ps --format '{{.Names}}' | grep -qx "$PG_CT" || die "找不到容器 $PG_CT"
mkdir -p "$OUT"

log "1/3 角色与权限（globals）"
docker exec -i "$PG_CT" pg_dumpall -U "$ADMIN_USER" --globals-only > "$OUT/globals.sql"
[[ -s "$OUT/globals.sql" ]] || die "globals.sql 是空的"
info "$(wc -l < "$OUT/globals.sql") 行  $OUT/globals.sql"

log "2/3 各库逻辑备份"
mapfile -t DBS < <(docker exec -i "$PG_CT" psql -U "$ADMIN_USER" -d postgres -Atc \
    "select datname from pg_database where not datistemplate order by 1")
(( ${#DBS[@]} > 0 )) || die "没有找到任何库"

for db in "${DBS[@]}"; do
    docker exec -i "$PG_CT" pg_dump -Fc -U "$ADMIN_USER" -d "$db" > "$OUT/$db.dump"
    [[ -s "$OUT/$db.dump" ]] || die "$db 的 dump 为空"
    info "$db  $(du -h "$OUT/$db.dump" | cut -f1)"
done

log "3/3 校验（每个 dump 能否列出目录）"
for db in "${DBS[@]}"; do
    # 先落文件再 grep：管道 + pipefail + grep -q 会被 SIGPIPE 误判
    docker exec -i "$PG_CT" pg_restore -l < "$OUT/$db.dump" > "$OUT/$db.toc" 2>/dev/null \
        || die "$db 的 dump 读不出来"
    n="$(grep -c 'TABLE DATA' "$OUT/$db.toc" || true)"
    info "$db  $n 张表有数据"
done

cat <<EOF

备份完成：$OUT
  globals.sql   角色与权限
  <db>.dump     每库一份（pg_restore -Fc 格式）

恢复见 docs/postgres.md。记得把 $OUT 拷到异地——它和数据库在同一台机器上。
EOF
