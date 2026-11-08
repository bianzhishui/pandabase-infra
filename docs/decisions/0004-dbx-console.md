# ADR 0004：运维控制台 DBX 与它的网关例外

- 状态：已接受
- 日期：2026-11-08
- 决策者：项目负责人
- 关联：[ADR 0001](0001-repo-boundary.md)、[ADR 0002](0002-postgres-platform.md)、[ADR 0003](0003-identity-provider.md)、`docs/edge.md`

## 背景

「人要看库」的场景只有两种：排障时核对真实数据、接新业务时建库并验证权限。
现在只能 `docker exec pandabase-postgres psql`——在手机上、或在没配 SSH 的机器上做不到。

DBX 是可自托管的数据库工作台：Apache-2.0、Rust 单进程、官方 Docker 镜像、
PostgreSQL 走原生驱动（不拉 JRE）、支持只读连接与生产保护二次确认。
但它的 Web 版**只有一个共享口令**：没有多用户、没有 OIDC、没有操作审计。
这一点决定了下面所有的取舍。

## 决策

1. **放 `deploy/dbx/`，独立 compose project `pandabase-dbx`。** 它是运维 UI，不是业务负载：
   不进 `docs/workload-onboarding.md` 的登记表，也不出现在 `docs/contract.md`
   「业务需要满足什么」里。业务方不需要知道它存在。

2. **只绑 `127.0.0.1:8002`**，公网只经宿主 Caddy 的 `dbx.pandabase.top`。
   不采用「专用宿主机 + 容器 Caddy」形态。

3. **允许在这一条链路上加 forward_auth 闸门——这是对 ADR 0001、ADR 0003 的显式例外。**
   那两份 ADR 否决「反代做鉴权」的理由是：反代注入的身份头可被直连回环伪造，而业务又信任这些头。
   DBX **完全不消费身份头**，所以那个失效模式在这里不成立。例外要成立，四个前提缺一不可：

   | 前提 | 不满足会怎样 |
   |---|---|
   | 不 `copy_headers`，不向 DBX 注入任何身份头 | 给「将来 DBX 支持 header 登录」留一条伪造后门 |
   | DBX 只经反代可达（`pandabase-ops` 网络隔离，业务容器不在该网） | 闸门被整个绕过，只剩口令 |
   | DBX 自己仍有口令 | 闸门成为唯一防线，而它的上游是网页表单 |
   | 闸门失效默认拒绝（Casdoor 的 Permission 必须建） | Casdoor 的行为是「不配权限 = 组织内全员可进」 |

   任何一条不满足，就退回「不加闸门、只走 SSH 隧道」——那是安全的默认态。

4. **闸门用 Casdoor 原生的 `GET /api/forward-auth`**，不引入 oauth2-proxy / Envoy / Traefik。
   它是纯闸门（200 / 401 / 403），只回答「放不放行」，不承担身份注入。

5. **镜像版本钉死**（当前 `0.6.64`），升级按变更处理。DBX 几乎日更，`latest` +
   `pull_policy: always` 等于每天早上换一个数据库控制台，出事时没有版本号可对。

6. **DBX 里只放只读账号**（`dbx_read`，由 `scripts/pg-provision.sh reader <库>` 建）。
   `pandabase_admin` 不写进连接列表——建库、恢复这类操作走 `psql` 或临时手输，
   不让实例级超级权限躺在一个共享口令后面。

7. **`pandabase_dbx_data` 不进异地备份。** 卷里同时有 `dbx.db` 与 `.dbx/secret.key`，
   拿到卷约等于拿到库口令；连接配置只有几条，丢了重建比泄露便宜。

## 被否决的方案

| 方案 | 否决理由 |
|---|---|
| 只走 SSH 隧道（`ssh -L 8002:127.0.0.1:8002`） | 最安全，但手机与临时借用的机器上没有 SSH 客户端；本次需求正是「任意浏览器可用」。仍保留为回滚路径 |
| 用 Casdoor 的 Sites（自带反代 + TLS） | 它要自己绑 443，与宿主 Caddy 抢端口，`auth` 的证书也会换人管 |
| oauth2-proxy / Envoy ext_authz / Traefik forwardAuth | 多一个容器、多一套 secret 与升级路径；Casdoor 原生 forward-auth 已够 |
| 只靠 `DBX_PASSWORD`，不加闸门 | 单因子、不可吊销、无 MFA；口令一旦落进某处就只能靠改口令收场 |
| 关掉 `DBX_PASSWORD`，只靠闸门 | 闸门成为唯一防线，而它的权限模型是「不配就全放行」 |
| DBX 直连 `pandabase` 网络 | 业务容器能直连 4224，等于绕开闸门——ADR 0001 担心的旁路的翻版，只是不用伪造头 |
| 给 DBX 用 `pandabase_admin` | 控制台一旦被攻破就是实例级；只读角色够日常用 |

## 后果

### 正面

- 任意浏览器可用，不用装客户端、不用记隧道命令
- 两层防护：Casdoor（可撤销、可开 MFA）+ DBX 口令
- 业务被攻破也够不到控制台（不在同一网络）
- 排障从「`docker exec` + `psql`」变成可视化，写操作有 SQL 预览

### 负面 / 需要承担

| 风险 | 说明 | 缓解 |
|---|---|---|
| 双重登录 | 先过 Casdoor，再输一次 DBX 口令 | 接受。控制台不是高频入口 |
| 安全开关在 Casdoor 的网页表单里 | Permission / Public paths 配错 = 门自己开了，且不进 git | 验收项固定为「禁用账号后 1 分钟内应 403」；每次改动后重跑 |
| PG 多挂一个网络 | `pandabase-ops` 是运行态状态，重建 PG 时要靠 compose 收敛 | 网络写进 `deploy/postgres/docker-compose.yml`，不让它只活在 `docker network connect` 里 |
| 多一个日更组件 | 小版本之间行为会变 | 钉版本 + 升级前在桌面版试同一操作 |
| 闸门依赖 Casdoor | Casdoor 挂了就进不去控制台 | 与业务 401 同一个故障源；PG 仍可用 `psql` 兜底 |
| 没有审计 | DBX 不记录谁执行了什么 | 单人运维下可接受；出现第二个改数据的人之前必须先补审计 |

## 重新评估条件

- 出现第二个需要改数据的人 → 先解决审计，再谈开权限
- 需要「谁批准了什么变更」→ DBX 不是审批系统，别拿「生产保护」当审批
- Casdoor 升级后 forward-auth 的语义变化（3xx / 401 / 头名）→ 复核 `docs/edge.md` 的实测记录
- DBX 支持 OIDC → 立即去掉共享口令，改由它自己校验令牌，本 ADR 的例外随之失效
