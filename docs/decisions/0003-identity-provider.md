# ADR 0003：身份由 Casdoor 统一提供

- 状态：已接受
- 日期：2026-11-08
- 决策者：项目负责人
- 关联：[ADR 0001](0001-repo-boundary.md)、业务仓库 `docs/decisions/0001-auth-architecture.md`、`0006-casdoor-audience.md`、`0007-no-dcr.md`

## 背景

平台上有多个业务，每个业务都是一个独立的 MCP 服务端（OAuth 2.1 Resource Server）。
它们需要：统一的登录入口、可撤销的令牌、按客户端粒度控制「谁能调我」。
业务侧不能被某个 IdP 的实现细节绑死，但也不该各自维护一套用户体系。

## 决策

1. **自部署 Casdoor 作为平台唯一授权服务器**，`https://auth.pandabase.top`。
   管理台只绑 `127.0.0.1:8001`，公网只经宿主 Caddy 暴露 `auth` 子域。
2. **issuer 不可变**。它写进每个 JWT 的 `iss`，改一次 = 所有令牌失效 + 所有客户端重配。
   所以域名必须在第一天就定死。
3. **一业务一 application**。每个业务有自己的 `client_id`、自己的 scope 命名空间
   （如 `baidu:read` / `baidu:write`）、自己的回调地址。新增业务不改动既有业务。
4. **DCR 保持关闭**，客户端逐个显式注册。实测（见业务仓库 ADR 0007）：DCR 没有回调白名单、
   没有限流，且它签出的令牌 `aud` 是新的 client_id，本来也调不动业务服务。
5. **`aud` 是 client_id，不是资源地址**。这是 Casdoor 的实测行为，不是 RFC 8707 的语义。
   业务侧因此把 audience 当**白名单**用：每个允许调用它的客户端，把 client_id 加进去。
6. **JWKS 路径显式配置**，不靠推导：实测在 `/.well-known/jwks`，不是常见的 `{issuer}/api/v1/jwks`。
7. **scope 在 Casdoor 里是对象数组**，不是字符串数组；写成 `["baidu:read"]` 会报
   `json: cannot unmarshal string into Go value of type object.ScopeItem`。

## 被否决的方案

| 方案 | 否决理由 |
|---|---|
| 托管 IdP（Auth0 / Clerk / 飞书扫码） | 按 MAU 计费；数据出境与合规不确定；免费额度随业务数增长而超 |
| 静态 bearer token + Caddy basic auth | 无按客户端撤销、无 scope 粒度、无过期；多业务下无法审计「谁调了谁」 |
| 反代做 OAuth（oauth2-proxy / Envoy） | 与「反代不做鉴权」冲突：反代注入的身份头可被直连回环伪造 |
| 开启 DCR 让客户端自助注册 | 无白名单、无限流，等于白送一个钓鱼用的注册端点；且签出的令牌调不动业务 |
| 每业务自建 IdP | 用户要登 N 次；令牌无法跨业务撤销；运维成本随业务数线性增长 |

## 后果

### 正面

- 一个登录入口覆盖所有业务；新增业务只是「建 application + 登记 scope」
- 业务侧只依赖标准 OAuth（iss / aud / exp / scope），不依赖 Casdoor 的私有协议
- 停用某个客户端 = 从业务的白名单里去掉一个 id，立即生效

### 负面 / 需要承担

| 风险 | 说明 | 缓解 |
|---|---|---|
| Casdoor 是单点 | 它挂了，所有业务都签不出新令牌 | 已签发令牌在有效期内仍可验证（JWKS 缓存 10 分钟）；缩短依赖链 |
| 客户端接入要靠手工 | 没有 DCR，每个客户端都要建应用、填回调、加白名单 | `scripts/` 里提供注册脚手架，把步骤固化成命令 |
| 版本迭代快 | `casbin/casdoor:latest` 曾出现字段与文档不符 | 实测记录在 `docs/identity.md`，升级前先比对 discovery |

## 重新评估条件

- 业务数 ≥ 5 且需要单点登录之外的差异化策略（组织、计费、审计分级）
- 需要 OIDC 之外的能力（SAML、SCIM、多因素强制）
- Casdoor 出现无法绕过的安全公告且无补丁 → 换 IdP 时业务侧不应改代码（只需换 issuer/audience/JWKS）
