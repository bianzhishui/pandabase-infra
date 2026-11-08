# 平台运维

范围：共享网络、PostgreSQL、Casdoor、宿主 Caddy。**业务的部署与排障在业务仓库**，
这里只写平台侧的动作。

## 一、启动与停止顺序

启动（从冷机开始）：

```bash
bash scripts/bootstrap-network.sh
docker compose -f deploy/postgres/docker-compose.yml up -d
docker compose -f deploy/casdoor/docker-compose.yml up -d
docker compose -f deploy/dbx/docker-compose.yml up -d
# 然后才是各业务自己的 compose
```

停止（维护窗口）：

```bash
# 反过来：先业务，再 DBX，再 Casdoor，最后 PG
```

跨 project 没有 `depends_on`，所以**顺序靠人保证**，容器用 `restart: unless-stopped` 兜底：
PG 未就绪时 Casdoor 会退出重启，直到连上库；DBX 连不上库时只是界面里报连接失败，不会退出。

## 二、日常检查

```bash
docker compose -f deploy/postgres/docker-compose.yml ps
docker compose -f deploy/casdoor/docker-compose.yml ps
docker compose -f deploy/dbx/docker-compose.yml ps
docker exec pandabase-postgres psql -U pandabase_admin -d postgres -c '\l'
curl -fsS https://auth.pandabase.top/.well-known/openid-configuration | head -c 80
curl -fsS https://baiduads.pandabase.top/healthz
# DBX：回环探针（不经过 Caddy），公网入口必须是被挡住的
curl -fsS http://127.0.0.1:8002/api/auth/check
curl -s -o /dev/null -w 'dbx 公网未登录: %{http_code}\n' https://dbx.pandabase.top/
```

日志：

```bash
docker compose -f deploy/postgres/docker-compose.yml logs --tail=50 postgres
docker compose -f deploy/casdoor/docker-compose.yml logs --tail=50 casdoor
docker compose -f deploy/dbx/docker-compose.yml logs --tail=50 dbx
sudo journalctl -u caddy -f
```

## 三、备份

每日一次（建议 cron，凌晨）：

```bash
bash scripts/pg-backup.sh
```

产物在 `backups/<YYYY-MM-DD>/`：`globals.sql` + 每个库一份 `.dump`。
**备份不在容器卷里**，需要单独拷走（异地或对象存储）。恢复见 `docs/postgres.md`。

## 四、故障表

| 现象 | 原因 | 处理 |
|---|---|---|
| 所有业务 401 | Casdoor 不可达 / JWKS 拉不到 | `compose ps`、`logs casdoor`，先确认 discovery 通 |
| 某业务 401、其它正常 | 该业务的 client_id 不在自己白名单 / scope 未登记 | 查该业务 `AUDIENCE` 与 Casdoor 应用 |
| 业务连不上库 | 不在 `pandabase` 网络 / 角色无权限 / DSN 错 | `docker exec pandabase-postgres psql -U <app> -d <app> -c 'select 1'` |
| `too many connections for role` | 业务连接池开太大 | 调业务连接池；必要时调该角色 `CONNECTION LIMIT` |
| 证书签发失败 | DNS 没有 A 记录 / 80 未放通 | `dig` + 安全组，别动容器 |
| 502 | 业务容器没起 / 端口不对 | 查业务 compose，再查 Caddy 上游 |
| PG 起不来 | 卷的 `PG_VERSION` 与镜像不匹配 | 别反复重启；按 `docs/postgres.md` 的升级/回滚处理 |
| DBX 登录后又跳回登录页 | `/caswaf-handler` 没路由给 Casdoor，或该应用的 Redirect URLs 没填这条 | 查 Caddy 的 `handle /caswaf-handler` 与该应用 Redirect URLs |
| DBX 一律 403 | Casdoor 里没建 Permission，或当前用户不在其中 | 补 Permission（`Application` 类型，resource=`dbx`） |
| DBX 公网能直接打开 | Site 没绑 `dbx` 应用 / Public paths 被写宽了 | **先注释掉 Caddy 的 dbx 站点块并 reload**，再查 Casdoor |
| DBX 502 | `pandabase-dbx` 没起 / 8002 没监听 | `compose ps`、`ss -lntp \| grep 8002` |
| DBX 连不上库 | 容器不在 `pandabase-ops` / PG 没加入该网络 / 角色无权限 | `docker network inspect pandabase-ops` 看两个容器都在 |
| DBX 里看不到新建的表 | 默认权限没设（`reader` 只在建角色那次设过） | 重跑 `bash scripts/pg-provision.sh reader <库>` |

## 五、变更窗口

需要停机的操作：PG 大版本升级、project 改名、角色降权、网络重建、
**给 PG 增删网络附件**（会重建容器，如本次给 DBX 开 `pandabase-ops`）。
单次窗口目标 ≤ 5 分钟，前置条件：备份完整 + 回滚命令已写好在手边。

不需要停机：新增业务库与角色、新增 Casdoor 应用、Caddy 加站点（reload 即生效）。

## 六、现状与待办

| 项 | 值 |
|---|---|
| 机器 | 49.232.229.71，2C2G |
| PostgreSQL | 17.11，`postgres:17-bookworm`，卷 `pandabase_pgdata`（迁移后） |
| Casdoor | `casbin/casdoor:latest`，`pandabase-casdoor`，端口 `127.0.0.1:8001` |
| DBX | `t8y2/dbx:0.6.64`，`pandabase-dbx`，端口 `127.0.0.1:8002`，卷 `pandabase_dbx_data`，只读角色 `dbx_read` |
| 网络 | `pandabase`（业务/Casdoor/PG）、`pandabase-ops`（PG/DBX），`bootstrap-network.sh` 创建 |
| 备份 | `backups/`，每日 |

待办：

- [x] PG 从旧 project `mybmo-casdoor` 迁到 `pandabase`（2026-11-08 20:01，见 `docs/postgres.md`）
- [x] `casdoor` 角色隔离：服务改用 `casdoor_app`，bootstrap 角色 `NOLOGIN` 封存
- [ ] 旧 project 与旧卷在第 7 天（2026-11-15）后删除
- [x] `app-built-in` 的 `password` grant 已关闭；业务改用专用 application `mybmo-mcp`
      （client_id `709a8e16656a223a1ab7`），2026-11-08 20:22
- [ ] `mybmo-mcp` 应用的 `redirect_uris` 待填（为空时授权码流程走不通）
- [ ] 客户端在新应用上跑通一次授权码流程后，从业务白名单里移除旧 `app-built-in` 的 client_id
- [ ] 备份加 cron 与异地留存
- [ ] `/healthz` 外部监控（当前只有容器 HEALTHCHECK）
- [ ] DBX：Casdoor 侧五处配置（Application / Redirect / Site / Permission / Public paths 留空），
      见 `docs/identity.md` 第七节
- [ ] DBX：`dbx_read` 口令存密码管理器，并在 DBX 里勾「Read-only connection」+「Production protection」
- [ ] DBX：确认镜像内有 `curl` 或 `wget` 后补 HEALTHCHECK
- [ ] DBX：`pandabase_dbx_data` 不进异地备份（卷内 `.dbx/secret.key` 约等于库口令），
      但要在本地密码管理器里另存一份连接清单
