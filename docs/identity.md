# 身份（Casdoor）

平台唯一的授权服务器：`https://auth.pandabase.top`。所有业务都是 OAuth 2.1 Resource Server，
只校验令牌、不签发令牌。

## 一、不可变的东西

| 项 | 值 | 为什么不能改 |
|---|---|---|
| issuer | `https://auth.pandabase.top` | 写进每个 JWT 的 `iss`；改一次 = 所有令牌失效 + 所有客户端重配 |
| 授权服务器实例 | 同一个 Casdoor | 多实例意味着多套 issuer，业务要同时信任多个 |
| DCR | `disabled` | 见下 |

管理台只绑 `127.0.0.1:8001`，公网只经宿主 Caddy 暴露 `auth` 子域。
**不要**把 `8000`/`8001` 直接映射到 `0.0.0.0`。

## 二、实测出来的三个坑（换版本前先复核）

| 坑 | 实测值 | 影响 |
|---|---|---|
| `aud` 是 client_id | 令牌里 `aud: ["60fda1..."]`，不是资源地址 | 业务侧把 audience 当**白名单**用；配成资源地址会全部 401 |
| JWKS 路径 | `/.well-known/jwks`（不是 `{issuer}/api/v1/jwks`） | 业务侧必须显式配 `*_JWKS_URL`，不要靠推导 |
| scope 是对象数组 | `[{"name":"baidu:read",...}]` | 写成 `["baidu:read"]` 会 `json: cannot unmarshal string into ... ScopeItem` |
| DCR 没有白名单/限流 | `POST /api/oauth/register` 接受任意 `redirect_uris` | 保持 `disabled`；客户端逐个显式注册 |
| `client_id_metadata_document_supported` | `false` | 客户端不能用 URL 当 client_id，只能手工建应用 |

复核命令：

```bash
curl -fsS https://auth.pandabase.top/.well-known/openid-configuration \
  | python3 -m json.tool | grep -E 'issuer|jwks_uri|registration_endpoint|client_id_metadata'
curl -fsS https://auth.pandabase.top/.well-known/jwks | head -c 200
```

## 三、新增一个业务（一业务一 application）

每一步都可回滚，顺序不要改：

1. Casdoor 控制台 → Applications → 新建，Name 用业务名（如 `mybmo-mcp`）
2. Redirect URL 填该客户端固定回调；只勾 `authorization_code` + `refresh_token`，
   **不要勾 `password`**（当前 `app-built-in` 还开着，属于待关项）
3. 在应用里登记该业务的 scope（对象数组形状），如 `baidu:read` / `baidu:write` / `baidu:admin`
4. 记下 client_id，交付业务方：它要加进自己的 audience 白名单
5. 把 client_id 与所属业务登记到 `docs/workload-onboarding.md`

## 四、停用一个客户端

从业务的白名单里删掉那个 client_id 并重启业务即可。**不要**靠删 Casdoor 应用来"顺手撤销"——
删应用后已签发令牌在过期前仍然有效，而业务的报错会变成难懂的 401。

## 五、Casdoor 自己的库

`casdoor` 库在平台 PG 上，角色 `casdoor` 已降权（非 superuser）。注意：

- Casdoor 用 xorm 自动建表，依赖它自己是库 owner，降权不影响这一点
- 恢复 `globals.sql`、建角色这类操作要用 `pandabase_admin`
- 备份见 `docs/postgres.md`；`casdoor` 库里除了账号，还有**JWT 签名证书**——
  这个库丢了等于换钥匙，所有令牌立即失效
