# 平台运维

范围：共享网络、PostgreSQL、Casdoor、DBX、宿主 Caddy。**业务的部署与排障在业务仓库**，
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
PG 未就绪时 Casdoor 会退出重启，直到连上库；DBX 连不上库只是界面里报连接失败，不会退出。

## 二、日常检查

```bash
docker compose -f deploy/postgres/docker-compose.yml ps
docker compose -f deploy/casdoor/docker-compose.yml ps
docker compose -f deploy/dbx/docker-compose.yml ps
docker exec pandabase-postgres psql -U pandabase_admin -d postgres -c '\l'
curl -fsS https://auth.pandabase.top:8443/.well-known/openid-configuration | head -c 80
curl -fsS https://baiduads.pandabase.top:8443/healthz
# DBX 只在回环：用宿主 curl 探，不经过任何反代
curl -fsS http://127.0.0.1:8002/api/auth/check
# Casdoor MCP 网关：未登录应 401（不是 502）
curl -s -o /dev/null -w 'dbx mcp gateway: %{http_code}\n' -X POST https://auth.pandabase.top:8443/api/server/built-in/dbx
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
| 客户端 `curl` 000 / `UNEXPECTED_EOF`，服务器侧 200，浏览器能开 | 未备案域名在 443 上按 SNI 被 RST | 确认 URL 带 `:8443`（ADR 0005）；不要为此改回 443 |
| 8443 上也开始 000 | 拦截规则升级到非标端口 | 别再换端口，转境外 VPS 回源（ADR 0005「重新评估条件」） |
| 证书快到期/握手报证书错误 | acme.sh 续期失败 | `sudo bash scripts/tls-wildcard.sh check`，再 `sudo ~/.acme.sh/acme.sh --cron`；看 `journalctl -u caddy` |
| 证书签发失败 | DNS 没有 A 记录 / DNS API 凭据过期 | `sudo bash scripts/tls-wildcard.sh issue` 看 acme.sh 报错；别动容器 |
| 502 | 业务容器没起 / 端口不对 | 查业务 compose，再查 Caddy 上游 |
| PG 起不来 | 卷的 `PG_VERSION` 与镜像不匹配 | 别反复重启；按 `docs/postgres.md` 的升级/回滚处理 |
| DBX 打不开 | SSH 隧道没开 / 8002 没监听 | 重开隧道；`ss -ltnp \| grep 8002`、`docs/dbx.md` |
| DBX 连接 timeout | DBX 或 PG 不在 `pandabase-ops` | `docker network inspect pandabase-ops` 应同时有两者 |
| DBX MCP 502 | Casdoor 够不到 DBX / Host 白名单不符 | 从 Casdoor 容器 `curl http://pandabase-dbx:4224/mcp`；查 `DBX_WEB_MCP_ALLOWED_HOSTS` |
| DBX MCP 401 | 正常（未登录）；登录后仍 401 查 application / 权限 | Casdoor 的 `built-in/dbx` server、`app-built-in`、用户组织 |
| DBX MCP 工具被拒 | 工具不在 Casdoor 的 allowlist | Casdoor `MCP Servers → dbx` 点 Sync，把需要的工具设为 allowed |

## 五、变更窗口

需要停机的操作：PG 大版本升级、project 改名、角色降权、网络重建、
**给 PG 增删网络附件**（会重建容器，例如加入 `pandabase-ops`）。
单次窗口目标 ≤ 5 分钟，前置条件：备份完整 + 回滚命令已写好在手边。

不需要停机：新增业务库与角色、新增 Casdoor 应用、Caddy 加站点（reload 即生效）、
新增 DBX 只读授权（`pg-provision.sh reader`）。

## 六、现状与待办

| 项 | 值 |
|---|---|
| 机器 | 49.232.229.71，2C2G |
| PostgreSQL | 17.11，`postgres:17-bookworm`，卷 `pandabase_pgdata`（66 MB）+ `pandabase_pglogs` |
| Casdoor | `casbin/casdoor:latest`，`pandabase-casdoor`，端口 `127.0.0.1:8001` |
| DBX | `t8y2/dbx:0.6.64`，`pandabase-dbx`，端口 `127.0.0.1:8002`（UI 仅 SSH 隧道） |
| 边缘 | **过渡态**：对外只有 `:8443`（443 保留、备案通过后切回，见 ADR 0005）；证书沿用 Caddy 托管的同名 LE 证书，2027-02-06 到期，切回 443 后自动续期 |
| DBX MCP | `https://auth.pandabase.top:8443/api/server/built-in/dbx`（Casdoor 网关，只读） |
| 网络 | `pandabase`（业务/身份/PG）、`pandabase-ops`（PG/DBX/Casdoor），均为 external |
| 备份 | `backups/`，每日 |

待办：

- [x] PG 从旧 project `mybmo-casdoor` 迁到 `pandabase`（2026-11-08 20:01，见 `docs/postgres.md`）
- [x] `casdoor` 角色隔离：服务改用 `casdoor_app`，bootstrap 角色 `NOLOGIN` 封存
- [x] 旧 project `mybmo-casdoor`、两个旧卷、目录副本已删除（2026-11-08 22:09，提前于 11-15）
      ——回滚退路随之消失，只剩 `backups/rename-2026-11-08-200101/` 里的 dump 与整卷 tar
- [x] `app-built-in` 的 `password` grant 已关闭；业务改用专用 application `mybmo-mcp`
      （client_id `709a8e16656a223a1ab7`），2026-11-08 20:22
- [x] `mybmo-mcp` 的 `redirect_uris` 已填（`http://127.0.0.1:33418/callback`）
- [x] 授权码流程已跑通（`aud=['709a8e16656a223a1ab7']`、`/mcp` 400），
      旧 `app-built-in` 的 client_id 已从白名单移除，`client_secret` 已轮换
- [x] DBX 恢复部署：独立 project、回环 `127.0.0.1:8002`、`pandabase-ops` 隔离、
      只读角色 `dbx_read`（2026-11-09，见 `docs/dbx.md`）
- [ ] 令牌有效期 `expire_in_hours=168`（7 天）偏长，建议改 1 小时 + refresh
- [ ] **备案通过后切回 443**（计划内，非可选）：清单见 ADR 0005「切回 443」；切之前先用公网 curl 验 443 已解除拦截
- [ ] 仅当备案拖到 2027-01 之后才做：证书续期切 DNS-01（需 DNSPod 凭据），硬期限 2027-02-06
- [x] ~~`MYBMO_BAIDU_CALLBACK_URL` 改 `:8443`~~ —— 不改：切回 443 后原值就是对的，
      改了反而要在百度后台改两次。**这个值全程不动**
- [ ] 重配 MCP 客户端（Claude Code / Cursor / VS Code）为 `:8443`，切回时再改回
- [ ] 业务仓库（`mybmo-mcp`）的 README / auth-contract / .env.example 仍是旧值，待该仓库同步
- [ ] 通配证书的续期结果纳入监控（续期失败时不会有人知道，直到握手报错）
- [ ] 备份加 cron 与异地留存
- [ ] `/healthz` 外部监控（当前只有容器 HEALTHCHECK）

## 七、代码怎么上线（这台机器拉不到 GitHub）

`/opt/pandabase-infra` 是仓库的 checkout，但**服务器直连 GitHub 会失败**
（`gnutls_handshake() failed: The TLS connection was non-properly terminated`），
所以它停在 2026-11-09 很久。部署路径因此是"从开发机推过去"，不是从服务器拉：

```bash
# 开发机：一次性配置（已配好）
git remote add deploy pandabase-dev01:/opt/pandabase-infra

# 之后每次上线：一条命令，直接更新服务器上的工作区
git push origin main      # 备份到 GitHub
git push deploy main      # 落到服务器 checkout
```

服务器那份 checkout 已设 `receive.denyCurrentBranch=updateInstead`，所以 push 会**同时更新
工作区文件**（工作区有本地改动时 push 会被拒，先处理掉再推）。

注意**仓库不等于线上运行态**。infra 里只有 Caddy 站点片段、compose、脚本；真正生效的是：

| 运行态 | 位置 | 由谁维护 |
|---|---|---|
| Caddy 站点 | `/etc/caddy/Caddyfile`（repo 里只是片段，需手工追加 + reload） | 人 |
| 容器环境变量 | `deploy/*/.env`（gitignore，不在仓库里） | 人 |
| 业务环境变量 | `/opt/mybmo-mcp/deploy/.env`（另一个仓库） | 业务仓库 |

所以「部署」= `git push deploy main` + 需要时手工 reload。没有 CI/CD，这是刻意的（见 ADR 0001）。
