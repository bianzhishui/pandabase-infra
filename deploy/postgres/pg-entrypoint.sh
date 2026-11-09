#!/bin/sh
#
# 官方 postgres 镜像的日志卷第一次挂载时是 root:root，而服务进程以 postgres 运行，
# 直接打开 logging_collector 会因权限不足起不来。这里在降权前修正属主，
# 再把参数交回官方 entrypoint，保持 initdb / gosu 的逻辑不变。
#
# 由 docker-compose.yml 的 entrypoint 调用（/bin/sh，不依赖宿主的可执行位）。

set -eu

mkdir -p /var/log/postgresql
chown -R postgres:postgres /var/log/postgresql

exec /usr/local/bin/docker-entrypoint.sh postgres "$@"
