# ADR 0004：DBX 数据库控制台（仅回环 + SSH 隧道）

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

此前试过给它加宿主 Caddy + Casdoor `forward_auth` 的公网入口，因域名/证书与
Casdoor Permission 配置的复杂度回退了。本次先恢复「能用、且不增加公网攻击面」的形态。

## 决策

1. **放 `deploy/dbx/`，独立 compose project `pandabase-dbx`。** 它是运维 UI，不是业务负载，
   不进 `docs/workload-onboarding.md` 的登记表，也不出现在 `docs/contract.md`。
2. **只绑 `127.0.0.1:8002`，不开放公网。** 本机通过 SSH 隧道访问
   （`ssh -L 8002:127.0.0.1:8002 ...`，见 `docs/dbx.md`）。
3. **只挂 `pandabase-ops` 网络**，该网络只有 PG 与 DBX。业务容器在 `pandabase` 上，
   解析不到也连不到 4224——业务被攻破不等于控制台被攻破。
4. **DBX 里只放只读账号**：`dbx_read`，由 `scripts/pg-provision.sh reader <库>` 建。
   `pandabase_admin` 不写进连接列表。
5. **镜像版本钉死**（当前 `0.6.64`）。DBX 几乎日更，`latest` + `pull_policy: always`
   等于每天早上换一个数据库控制台，出事时没有版本号可对。
6. **`pandabase_dbx_data` 不进异地备份。** 卷里同时有 `dbx.db` 与 `.dbx/secret.key`，
   拿到卷约等于拿到库口令；连接配置只有几条，丢了重建比泄露便宜。
7. **共享口令是唯一登录门槛**，所以：禁用口令回看（`DBX_DISABLE_PASSWORD_VIEWER=1`）、
   限制上传（`DBX_MAX_UPLOAD_MB=64`）、512 MB 内存上限、日志轮转。

## 被否决的方案

| 方案 | 否决理由 |
|---|---|
| 公网 + Casdoor `forward_auth` 闸门 | 单共享口令 + 网页表单作为唯一第二因子；还依赖 Casdoor Permission/Public paths 的网页配置，配错即门开。等有第二个改数据的人、并补上审计后再评估 |
| 只靠 `DBX_PASSWORD` 直接暴露公网 | 单因子、不可吊销、无 MFA、无审计；数据库控制台不该这样放出去 |
| DBX 加入 `pandabase` 业务网络 | 业务容器可直连 4224，隔离失效 |
| 给 DBX 用 `pandabase_admin` | 控制台一旦被攻破就是实例级权限；只读角色够日常用 |
| 关掉 `DBX_PASSWORD`，只留反代闸门 | 闸门成为唯一防线，而 Casdoor 的行为是「不配 Permission = 全放行」 |
| 不部署，继续只用 `psql` | 手机上/临时机器上不可用；这正是本次要解决的 |

## 后果

### 正面

- 任意机器只要能 SSH，就能用浏览器看库，不用装客户端
- 业务网络隔离，控制台不在业务的 blast radius 里
- 只读角色 + 生产保护，误操作面比 `psql` 小

### 负面 / 需要承担

| 风险 | 说明 | 缓解 |
|---|---|---|
| 共享口令 | 无多用户、无法按人吊销、无审计 | 单人运维下接受；出现第二个改数据的人之前必须先补审计 |
| 访问要 SSH | 手机上体验一般 | 临时需要公网时再按「重新评估条件」补闸门 |
| 多一个日更组件 | 小版本行为会变 | 钉版本 + 升级前在桌面版试同一操作 |
| 卷里有连接口令的密钥 | 卷泄露=库口令泄露 | 卷不进备份；宿主机只有 ops 网络可达 |

## 重新评估条件

- 需要「任意浏览器、不装 SSH」→ 先补齐 Casdoor `forward_auth` 的四个前提
  （不注入身份头、DBX 只经反代可达、DBX 仍有口令、Permission 未配时默认拒绝），
  并在验收里加「禁用账号后 1 分钟内 403」
- DBX 支持 OIDC → 立即去掉共享口令，改由它自己校验令牌
- 出现第二个需要改数据的人 → 先解决审计，再谈开权限
