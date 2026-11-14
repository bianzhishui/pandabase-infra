# 身份（Casdoor）

平台唯一的授权服务器：`https://auth.pandabase.top:8443`。所有业务都是 OAuth 2.1 Resource Server，
只校验令牌、不签发令牌。

> 端口 8443 不是随手挑的：域名未备案，443 上的 TLS 被中间设备按 SNI 重置，对外入口
> 整体挪到 8443，见 [ADR 0005](decisions/0005-alt-port-tls.md)。**端口是 issuer 的一部分**，
> 漏了端口会得到 `iss` 不匹配导致的 401。

## 一、不可变的东西

| 项 | 值 | 为什么不能改 |
|---|---|---|
| issuer | `https://auth.pandabase.top:8443` | 写进每个 JWT 的 `iss`；改一次 = 所有令牌失效 + 所有客户端重配（2026-11-14 已为绕备案拦截改过一次，见 ADR 0005） |
| 授权服务器实例 | 同一个 Casdoor | 多实例意味着多套 issuer，业务要同时信任多个 |
| DCR | 业务应用 `disabled`；built-in 组织 `public`（仅 Casdoor MCP 网关） | 见下 |
| `client_id_metadata_document_supported` | 开启 built-in DCR 后为 `true` | MCP 客户端可用 URL 当 client_id；业务应用仍手工注册 |

管理台只绑 `127.0.0.1:8001`，公网只经宿主 Caddy 暴露 `auth` 子域。
**不要**把 `8000`/`8001` 直接映射到 `0.0.0.0`。

## 二、实测出来的三个坑（换版本前先复核）

| 坑 | 实测值 | 影响 |
|---|---|---|
| `aud` 是 client_id | 令牌里 `aud: ["60fda1..."]`，不是资源地址 | 业务侧把 audience 当**白名单**用；配成资源地址会全部 401 |
| JWKS 路径 | `/.well-known/jwks`（不是 `{issuer}/api/v1/jwks`） | 业务侧必须显式配 `*_JWKS_URL`，不要靠推导 |
| scope 是对象数组 | `[{"name":"baidu:read",...}]` | 写成 `["baidu:read"]` 会 `json: cannot unmarshal string into ... ScopeItem` |
| DCR 没有白名单/限流 | `POST /api/oauth/register` 接受任意 `redirect_uris` | 业务应用保持 `disabled`；built-in 仅为 Casdoor MCP 网关开启（见 ADR 0004） |

复核命令：

```bash
curl -fsS https://auth.pandabase.top:8443/.well-known/openid-configuration \
  | python3 -m json.tool | grep -E 'issuer|jwks_uri|registration_endpoint|client_id_metadata'
curl -fsS https://auth.pandabase.top:8443/.well-known/jwks | head -c 200
```

> **built-in 组织的 `dcr_policy=public` 只为 Casdoor MCP 网关服务**（见 `docs/dbx.md`）。
> 业务应用不在 built-in，因此业务侧「不用 DCR」的结论不变；关掉它会让 Claude/Cursor
> 等 MCP 客户端无法注册，但不会影响业务令牌的 audience 模型。

## 三、当前应用清单

| 应用 | client_id | grant_types | redirect_uris | 用途 |
|---|---|---|---|---|
| `mybmo-mcp` | `709a8e16656a223a1ab7` | `authorization_code` + `refresh_token` | `https://auth.pandabase.top:8443/apps`、`http://127.0.0.1:33418/callback` | 业务专用（2026-11-08 建）；33418 是 `scripts/verify-oauth.py` 的本地回调 |
| `app-built-in` | `60fda1d9bedd4615eb90` | `authorization_code` + `refresh_token` | 空 | Casdoor 自带示例，**password grant 已于 2026-11-08 关闭**；已不在任何业务的白名单里 |
| `dcr_*`（当前 3 个） | 客户端自助注册 | `authorization_code` + `refresh_token` | `http://localhost:<port>/oauth/callback` | MCP 客户端经 built-in DCR 注册（见 ADR 0004）；需定期清理 |

新应用是从 `app-built-in` 复制出来的（scope 数组一并带过来），
client_secret 在 Casdoor 控制台 `Applications → mybmo-mcp` 里查看，不要写进仓库。

> **`redirect_uris` 为空意味着授权码流程走不通。** 接具体客户端前必须把该客户端的
> 固定回调填进去（例：`https://claude.ai/api/mcp/auth_callback`），一个客户端一个 URI。
> 填完不需要重启 Casdoor，重新发起登录即可。
>
> `mybmo-mcp` 的 `https://auth.pandabase.top:8443/apps` 是建应用时 UI 带上的 Casdoor 自身路径，
> 与业务无关，确认没用后可删（授权码流程实际走 33418 回调）。加端口那次必须同步改它，
> 否则 Casdoor 自己那几条跳转会把用户带回 443。

## 四、新增一个业务（一业务一 application）

每一步都可回滚，顺序不要改：

1. Casdoor 控制台 → Applications → 新建，Name 用业务名（如 `mybmo-mcp`）
2. Redirect URL 填该客户端固定回调；只勾 `authorization_code` + `refresh_token`，
   **不要勾 `password`**
3. 在应用里登记该业务的 scope（对象数组形状），如 `baidu:read` / `baidu:write` / `baidu:admin`
4. 记下 client_id，交付业务方：它要加进自己的 audience 白名单
5. 把 client_id 与所属业务登记到 `docs/workload-onboarding.md`

## 五、停用一个客户端

从业务的白名单里删掉那个 client_id 并重启业务即可。**不要**靠删 Casdoor 应用来"顺手撤销"——
删应用后已签发令牌在过期前仍然有效，而业务的报错会变成难懂的 401。

## 六、Casdoor 自己的库

`casdoor` 库在平台 PG 上，角色 `casdoor` 已降权（非 superuser）。注意：

- Casdoor 用 xorm 自动建表，依赖它自己是库 owner，降权不影响这一点
- 恢复 `globals.sql`、建角色这类操作要用 `pandabase_admin`
- 备份见 `docs/postgres.md`；`casdoor` 库里除了账号，还有**JWT 签名证书**——
  这个库丢了等于换钥匙，所有令牌立即失效

## 七、验证与排查

**工具**：`python3 scripts/verify-oauth.py`——起回环监听 → 浏览器授权（PKCE S256 + state）
→ 换 token → 解 `aud`/`scope` → 带令牌调一次 `/mcp`。`/mcp` 返回 400/406 表示身份已通过
（MCP 握手拒绝空 body），401 才是没通过。

**先确认你用的是 8443。** 443 在大陆机器上会被备案拦截按 SNI 直接 RST（ADR 0005），
脚本默认 `--issuer` 已经是 `https://auth.pandabase.top:8443`。

**若 8443 也被掐**（症状：`curl` 返回 000、Python 抛 `SSL: UNEXPECTED_EOF_WHILE_READING`，
而同域名的浏览器能开、服务器侧 curl 200），说明拦截规则升级了，别换端口——
转境外 VPS 回源（ADR 0005「重新评估条件」）。临时可用把脚本放到服务器跑、
用 SSH 隧道接回浏览器回调的办法：

```bash
# 本机：转发回调端口
ssh -N -L 33418:127.0.0.1:33418 ubuntu@<host>

# 服务器：监听并把授权 URL 打出来（-u 必须有，否则 stdout 缓冲看不到 URL）
cd /opt/pandabase-infra
CASDOOR_CLIENT_ID=<cid> CASDOOR_CLIENT_SECRET=<secret> \
  python3 -u scripts/verify-oauth.py --no-browser --timeout 900
```

**令牌有效期**：`expire_in_hours` 从 `app-built-in` 继承过来是 **168（7 天）**，
`refresh_expire_in_hours=0`。对 MCP 客户端偏长——拿到一次令牌就能用一周，且无法按天撤销。
建议在控制台应用页改成 **1 小时 + refresh token**，真正的长会话交给 refresh。

**client_secret 泄露处置**：一旦出现在终端历史或对话里，立即在控制台重新生成，
并同步更新客户端配置；旧 secret 不会自动失效。
