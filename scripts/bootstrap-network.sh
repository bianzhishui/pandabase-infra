#!/usr/bin/env bash
#
# 创建共享容器网络。幂等，重复执行无副作用。
#
# 为什么不让 compose 创建：一旦由某个 project 创建，那个 project 的 `compose down`
# 就会把网络删掉，所有业务瞬间失联。所以网络声明为 external，由本脚本一次性创建。
#
# 两个网络：
#   pandabase      业务 / 身份 / PG 共用
#   pandabase-ops  只有 PG 与 DBX（见 docs/decisions/0004）——数据库控制台与业务容器
#                  不同网，业务被攻破也够不到它。加新服务时先想清楚「谁需要看见谁」，
#                  不要把服务默认丢进 pandabase。

set -euo pipefail
source "$(dirname "$0")/lib.sh"

NETWORKS="${NETWORKS:-pandabase pandabase-ops}"

need_cmd docker

read -r -a nets <<<"$NETWORKS"
existing="$(docker network ls --format '{{.Name}}')"
for net in "${nets[@]}"; do
    if grep -qx "$net" <<< "$existing"; then
        info "网络 $net 已存在"
    else
        docker network create "$net" >/dev/null
        info "已创建网络 $net"
    fi
    docker network inspect "$net" --format "   driver={{.Driver}} scope={{.Scope}}"
done
