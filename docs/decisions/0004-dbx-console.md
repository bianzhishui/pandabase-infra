# ADR 0004：DBX 控制台与 Casdoor MCP 网关

- 状态：已接受
- 日期：2026-11-09
- 决策者：项目负责人
- 关联：[ADR 0001](0001-repo-boundary.md)、[ADR 0002](0002-postgres-platform.md)、[ADR 0003](0003-identity-provider.md)、`docs/dbx.md`

## 背景

「人要看库」的场景只有两种：排障时核对真实数据、接新业务时建库并验证权限。
现在只能 `docker exec pandabase-postgres psql`——在手机上、或在没配 SSH 的机器上做不到。

DBX 是可自托管的数据库工作台：Apache-2.0、Rust 单进程、官方 Docker 镜像、
PostgreSQL 走原生驱动（不拉 JRE）、支持只读连接与生产保护二次确认。
但它的 Web 版**只有一个共享口令**：没有多用户、没有 OIDC、没有操作审计。

同时，AI 客户端需要以 MCP 方式读库。DBX Web 自带 Streamable HTTP MCP
（`/mcp`，Bearer token），Casdoor 有 MCP 网关（把上游 MCP Server 挂到
`/api/server/<org>/<name>`，由 Casdoor 做 OAuth 登录与工具白名单）。
两者组合起来，正好把「共享口令的 UI」和「需要 SSO 的 MCP」分开。

## 决策

1. **放 `deploy/dbx/`，独立 compose project `pandabase-dbx`。** 它是运维 UI，不是业务负载，
   不进 `docs/workload-onboarding.md` 的登记表，也不出现在 `docs/contract.md`。
2. **UI 只绑 `127.0.0.1:8002`，不开放公网。** 通过 SSH 隧道访问
   （`ssh -L 8002:127.0.0.1:8002 ...`，见 `docs/dbx.md`）。
3. **DBX 只挂 `pandabase-ops` 网络**。该网络放 PG、DBX 和 Casdoor：
   Casdoor 是 MCP 网关，必须够到 DBX；业务容器在 `pandabase` 上，解析不到 4224。
4. **DBX 里只放只读账号**：`dbx_read`，由 `scripts/pg-provision.sh reader <库>` 建。
   UI 里可能另有管理员连接供人工操作，但 **MCP 的 allowlist 只允许只读连接**。
5. **DBX MCP 只经 Casdoor 发布，不直连公网。**
   - 上游：`http://pandabase-dbx:4224/mcp`，Bearer token 存在 `deploy/dbx/.env`
     与 Casdoor 的 server 记录里；Host 白名单只认 `pandabase-dbx:4224`。
   - 网关：`https://auth.pandabase.top/api/server/built-in/dbx`。
   - Casdoor 转发时删除调用方的 `Cookie`/`Authorization`，注入 DBX token；
     DBX 不接收任何身份头，因此「伪造头直连回环」的旁路不成立。
6. **MCP 策略是只读且按连接收窄**：`readOnly=true`，只允许
   `pandabase-casdoor (read-only)` 这一条连接，只放 7 个读工具
   （list/database/table/schema/describe/query）。写操作在 DBX 侧直接拒绝，
   数据库账号 `dbx_read` 本身也没有写权限——两层都关。
7. **Casdoor 的 DCR/CIMD 只为 MCP 客户端开启。**
   built-in 组织的 `dcr_policy=public` 是为了让 Claude/Cursor/VS Code 能注册或使用
   client ID metadata；业务 MCP 应用仍不依赖 DCR，ADR 0003 的「业务侧不用 DCR」不变。
   网关仍要求用户登录 Casdoor、并且能使用 server 绑定的 application（当前是 `app-built-in`），
   所以「注册一个客户端」本身拿不到数据。
8. **镜像版本钉死**（当前 `0.6.64`）。DBX 几乎日更，`latest` + `pull_policy: always`
   等于每天早上换一个数据库控制台，出事时没有版本号可对。
9. **`pandabase_dbx_data` 不进异地备份。** 卷里同时有 `dbx.db` 与 `.dbx/secret.key`，
   拿到卷约等于拿到库口令；连接配置只有几条，丢了重建比泄露便宜。
10. **UI 的共享口令是第二道防线**：禁用口令回看、限制上传、512 MB 内存上限、日志轮转。

## 被否决的方案

| 方案 | 否决理由 |
|---|---|
| DBX UI 直接暴露公网（只靠共享口令） | 单因子、不可吊销、无 MFA、无审计 |
| 宿主 Caddy `forward_auth` + DBX UI | 仍是共享口令的单层防线；且要维护 Casdoor Permission/Public paths 的网页配置，配错即门开 |
| DBX 加入 `pandabase` 业务网络 | 业务容器可直连 4224，隔离失效 |
| 给 MCP 用 `pandabase_admin` | MCP 一旦被滥用就是实例级权限；只读连接足够 |
| DBX MCP 不设 token，只靠网络隔离 | Casdoor 或 ops 网络内任一进程都能直连；token 是上游自己的边界 |
| 为业务应用打开 DCR | ADR 0003 的结论不变：业务令牌的 audience 语义不适合 DCR 自助注册 |
| 不部署 MCP，只保留 UI | AI 客户端无法读库；这正是本次需求 |

## 后果

### 正面

- UI 仍只在回环，攻击面不变；MCP 走 Casdoor SSO，可按用户/应用撤销
- 业务容器不在 ops 网络，控制台与 MCP 上游都不在业务的 blast radius 里
- MCP 只读 + 单连接 + 7 个工具，模型能看库但不能改
- Casdoor 注入 token，调用方永远拿不到 DBX 的 Bearer token

### 负面 / 需要承担

| 风险 | 说明 | 缓解 |
|---|---|---|
| Casdoor 成为 MCP 的信任中心 | Casdoor 被攻破可拿到 DBX MCP（仍是只读） | 只读 token、单连接、工具白名单；DBX UI 仍需口令 |
| built-in 组织开了 DCR | 任何人都能注册一个客户端 | 注册后仍需登录与 application 授权；监控 `dcr_` 应用，定期清理 |
| MCP 工具面变化 | DBX 升级可能新增工具/字段 | 工具列表已落库；升级后先 Sync 再复核 allowlist |
| 共享口令的 UI | 无审计、无法按人吊销 | 单人运维下接受；出现第二个改数据的人之前先补审计 |
| 多一个日更组件 | 小版本行为会变 | 钉版本 + 升级前在桌面版试同一操作 |
| 卷里有连接口令的密钥 | 卷泄露=库口令泄露 | 卷不进备份；宿主机只有 ops 网络可达 |

## 重新评估条件

- 出现第二个需要使用 MCP 或 UI 改数据的人 → 先补审计与按人授权，再扩大范围
- DBX 支持 OIDC → 去掉 UI 共享口令，ADR 的「共享口令」部分失效
- DCR 出现滥用（大量 `dcr_` 应用）→ 关闭 built-in DCR，改为手工注册客户端
- Casdoor 网关支持按工具/参数更细的策略 → 把 DBX 的 7 个工具再收窄

## 修订（2026-11-10）：实施偏差

第 4、6 条的目标状态不变，但当前实际配置与之不符：MCP 策略的连接白名单指向
`pandabase`（`pandabase_admin`，实例级超管），而不是只读连接
`pandabase-casdoor (read-only)`（`dbx_read`）。只读仍由 DBX 的 `readOnly` 策略兜住，
但账号权限面比设计大。收紧动作见 `docs/dbx.md`「五、安全边界」末条。
