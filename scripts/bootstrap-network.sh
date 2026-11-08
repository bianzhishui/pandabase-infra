#!/usr/bin/env bash
#
# 创建共享容器网络 pandabase。幂等，重复执行无副作用。
#
# 为什么不让 compose 创建：一旦由某个 project 创建，那个 project 的 `compose down`
# 就会把网络删掉，所有业务瞬间失联。所以网络声明为 external，由本脚本一次性创建。

set -euo pipefail
source "$(dirname "$0")/lib.sh"

NETWORK="${NETWORK:-pandabase}"

need_cmd docker

existing="$(docker network ls --format '{{.Name}}')"
if grep -qx "$NETWORK" <<< "$existing"; then
    info "网络 $NETWORK 已存在"
else
    docker network create "$NETWORK" >/dev/null
    info "已创建网络 $NETWORK"
fi

docker network inspect "$NETWORK" --format '   driver={{.Driver}} scope={{.Scope}}'
