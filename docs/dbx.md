# DBX 数据库控制台

运维用，不是业务负载。**UI 只绑回环、不开放公网**，通过 SSH 隧道访问；
**MCP 只经 Casdoor 网关发布**，不直连公网。

```text
你的机器 ──ssh -L 8002──▶ 宿主 127.0.0.1:8002 ──▶ pandabase-dbx:4224（UI）
                                                       │
                                                       └─ pandabase-ops ─▶ pandabase-postgres:5432

MCP 客户端 ──https──▶ auth.pandabase.top/api/server/built-in/dbx（Casdoor 登录 + 工具白名单）
                          └─ pandabase-ops ─▶ pandabase-dbx:4224/mcp（Bearer token）
```

业务容器在 `pandabase` 网络上，不在 `pandabase-ops`，因此解析不到 DBX；
Casdoor 在 ops 网络里，只为了做 MCP 网关。

## 一、访问

在需要看库的机器上开隧道（保持这个终端不关）：

```bash
ssh -i ~/Downloads/dev01.pem -L 8002:127.0.0.1:8002 ubuntu@49.232.229.71
```

浏览器打开 `http://127.0.0.1:8002`。

登录口令在服务器的 `deploy/dbx/.env`（`DBX_PASSWORD`，600，git 忽略）：

```bash
ssh -i ~/Downloads/dev01.pem ubuntu@49.232.229.71 'cat /opt/pandabase-infra/deploy/dbx/.env'
```

## 二、数据库连接

DBX 的「新建连接」填：

| 字段 | 值 |
|---|---|
| Host | `pandabase-postgres` |
| Port | `5432` |
| Database | `casdoor`（按需） |
| User | `dbx_read` |
| Password | 见 `/home/ubuntu/dbx-read.dsn`（600，一次性生成后保存） |

完整 DSN：

```text
postgresql://dbx_read:<口令>@pandabase-postgres:5432/casdoor
```

连接勾选 **Read-only connection**，并打开 **Production protection**。
`dbx_read` 由 `scripts/pg-provision.sh reader <库>` 建：只授该库的 `SELECT`，
并设置默认权限覆盖今后新建的表。需要看别的库时重跑一次脚本，不跨库授权。

## 三、MCP（Casdoor 网关）

DBX Web 自带 Streamable HTTP MCP。它不直接暴露，只让 Casdoor 的 MCP 网关访问。

| 项 | 值 |
|---|---|
| 上游端点 | `http://pandabase-dbx:4224/mcp` |
| 上游 token | `deploy/dbx/.env` 的 `DBX_MCP_TOKEN` |
| 上游 Host 白名单 | `pandabase-dbx:4224` |
| 网关 URL | `https://auth.pandabase.top/api/server/built-in/dbx` |
| Casdoor 记录 | `built-in/dbx`，application `app-built-in` |
| 权限 | 只读；只允许 `pandabase-casdoor (read-only)` 连接；7 个读工具 |

客户端配置：

```bash
# Claude Code
claude mcp add --transport http dbx https://auth.pandabase.top/api/server/built-in/dbx
```

```json
// Cursor（~/.cursor/mcp.json）或 VS Code（.vscode/mcp.json，type 写 http）
{ "mcpServers": { "dbx": { "url": "https://auth.pandabase.top/api/server/built-in/dbx" } } }
```

首次连接会跳 Casdoor 登录；用 `built-in` 组织的管理员账号。客户端通过
DCR（Cursor）或 client ID metadata（Claude/VS Code）注册，built-in 组织的
DCR/CIMD 已为此开启——业务应用仍不走 DCR（见 ADR 0003/0004）。

对外暴露的工具只有 7 个：

```text
dbx_list_connections / dbx_list_databases / dbx_list_tables /
dbx_describe_table / dbx_get_schema_context / dbx_get_routine_source /
dbx_execute_query
```

`dbx_execute_query` 能执行 SQL，但 DBX 策略是 `readOnly`，写语句会直接返回
`MCP_READ_ONLY`；下游 `dbx_read` 本身也没有写权限。

### 验证

```bash
# 未登录应是 401，并带 protected-resource metadata
curl -i -X POST https://auth.pandabase.top/api/server/built-in/dbx

# 元数据
curl -fsS https://auth.pandabase.top/.well-known/oauth-protected-resource/api/server/built-in/dbx

# 本机看 DBX 侧的 MCP 状态（需要 DBX 登录 cookie）
curl -sS -b <cookie> http://127.0.0.1:8002/api/app-settings/mcp-http-status
```

### 改策略 / 换 token

- **策略**（只读、允许的连接、工具白名单）：DBX UI 的 Settings → MCP，
  或 `PUT /api/app-settings/mcp-policy`。当前策略通过 API 固化，不依赖 UI 点击。
- **换 DBX MCP token**：改 `deploy/dbx/.env` 的 `DBX_MCP_TOKEN` →
  `up -d` 重建 DBX → 把新 token 填到 Casdoor 的 `MCP Servers → dbx → Access token`
  （UI 保存时 token 留空表示沿用旧值；直接改会覆盖）。
- **新增库**：先 `pg-provision.sh reader <库>`，再在 DBX 里建只读连接，
  最后把新连接 ID 加进 MCP 策略的 `allowedConnectionIds`。

> Casdoor 侧的 `server` 记录（`built-in/dbx`）和 built-in 的 `dcr_policy=public`
> 存在 Casdoor 的 PostgreSQL 里，不在 git。换库或重建 Casdoor 后，需要在
> **LLM AI → MCP Servers** 重新添加并点 **Sync**，同时把 built-in 的 DCR 打开。

> DBX UI 里可能有一条用 `pandabase_admin` 的连接（人工排障用）。
> MCP 策略只允许 `pandabase-casdoor (read-only)`，所以 MCP 客户端看不到它，
> 也调不动它。不要把管理员连接加进 MCP allowlist。

## 四、启停与检查

```bash
# 启动（先 PG）
docker compose -f deploy/dbx/docker-compose.yml up -d

# 停止
docker compose -f deploy/dbx/docker-compose.yml down

# 检查
docker compose -f deploy/dbx/docker-compose.yml ps
curl -fsS http://127.0.0.1:8002/api/auth/check
docker network inspect pandabase-ops --format '{{range .Containers}}{{.Name}} {{end}}'
docker compose -f deploy/dbx/docker-compose.yml logs --tail=50 dbx
```

公网可达性验收（应该连不上）：

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 https://dbx.pandabase.top/
```

## 五、安全边界

- **UI 不开放公网，也不加 Caddy 站点**。需要「任意浏览器可用」时先看
  [ADR 0004](decisions/0004-dbx-console.md) 的重新评估条件，别直接加站点。
- **MCP 只经 Casdoor 网关**。DBX 的 `/mcp` 只接受 Bearer token，Host 白名单只认
  `pandabase-dbx:4224`；Casdoor 转发时删掉调用方的 `Cookie`/`Authorization`，
  再注入 DBX token。反向代不注入任何身份头，DBX 也不消费身份头。
- **DBX 只挂 `pandabase-ops`**（PG、DBX、Casdoor）。不要把它加进 `pandabase`
  业务网络。
- **MCP 只放只读连接**。UI 里的管理员连接保留给人工排障，不要加进 MCP allowlist。
- **相当于是两层账号**：Casdoor 决定谁能进网关，`dbx_read` 决定能读哪些表。
- 卷 `pandabase_dbx_data` 里有连接口令的加密密钥，**不进异地备份**。

## 六、升级

镜像钉在 `t8y2/dbx:0.6.64`。升级按变更做：先改 compose 里的 tag，
在桌面版把常用操作跑一遍，再 `up -d`。回滚就是把 tag 改回去再 `up -d`。
升级后到 Casdoor 的 `MCP Servers → dbx` 点一次 **Sync**，复核新增工具是否该放行。

## 七、故障表

| 现象 | 原因 | 处理 |
|---|---|---|
| 浏览器打不开 | 隧道没开 / 端口被占 | 重新开 `ssh -L 8002:...`；`ss -ltnp \| grep 8002` |
| 登录后又回登录页 | 口令错 / `.env` 改了没重建 | 看 `logs dbx`；`up -d` 让新口令生效 |
| 连接报 timeout | DBX 不在 `pandabase-ops` / PG 不在该网络 | `docker network inspect pandabase-ops` 应同时有 PG 与 DBX |
| 连接报密码错 | `dbx_read` 口令被轮换过 | 重新 `ALTER ROLE dbx_read PASSWORD ...`，或重跑 `reader` |
| 看不到新建的表 | 默认权限没覆盖 | 重跑 `bash scripts/pg-provision.sh reader <库>` |
