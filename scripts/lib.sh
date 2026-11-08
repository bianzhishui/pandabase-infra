#!/usr/bin/env bash
#
# 公共函数。被其它脚本 source，不单独执行。
#
# 注意两条踩过的坑：
#   1. 不要写 `cmd | grep -q ...`。grep 命中即退出会让上游吃 SIGPIPE，
#      配 `set -o pipefail` 时整条管道返回 141，"校验通过"会被误判成失败。
#      校验一律先重定向到文件或变量，再判断。
#   2. 通过 `ssh host 'bash -s' < script.sh` 执行时，`docker compose exec` 会抢 stdin
#      把剩余脚本吃掉。远端执行请先 scp 再 `bash /path`。

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   ! %s\n' "$*" >&2; }
die() { printf '\n失败：%s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

# 取 .env 里某个键的值（不 source，避免口令里的特殊字符被展开）
env_get() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    sed -nE "s/^[[:space:]]*${key}=//p" "$file" | tail -n1
}

# 等 PG 就绪
wait_pg() {
    local ct="$1" user="${2:-postgres}" tries="${3:-90}"
    local i
    for i in $(seq 1 "$tries"); do
        docker exec "$ct" pg_isready -U "$user" -d postgres >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# 生成不含 URL 保留字符的口令
gen_password() {
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24
}
