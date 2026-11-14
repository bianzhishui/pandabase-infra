# 平台与业务的契约

这是两个仓库之间**唯一**需要对齐的东西。infra 只公布「值」和「约束」，不规定业务用什么变量名、
不引用业务的文件路径。

## 一、infra 提供什么

| 项 | 值 | 备注 |
|---|---|---|
| 共享网络 | `pandabase` | 由 `scripts/bootstrap-network.sh` 创建；业务 compose 用 `external: true` |
| PostgreSQL | `pandabase-postgres:5432` | 只在 `pandabase` 网络内可达；宿主回环另有 `127.0.0.1:5432`，仅供 SSH 隧道/DBX，**公网不可达** |
| 业务库与角色 | `<app>` / 角色 `<app>` | 由 `scripts/pg-provision.sh` 建，最小权限、带连接数上限 |
| DSN 模板 | `postgresql://<app>:<pwd>@pandabase-postgres:5432/<app>` | 口令由 infra 生成后一次性交付 |
| 授权服务器 | `https://auth.pandabase.top:8443` | issuer 不可变，**端口也算 issuer 的一部分**（ADR 0005）|
| JWKS | `https://auth.pandabase.top:8443/.well-known/jwks` | 不要按 `{issuer}/api/v1/jwks` 推导 |
| 每个业务的 client_id | Casdoor 应用 ID | 业务把它加进自己的 audience 白名单 |
| TLS / 域名 | 宿主 Caddy，对外只有 `:8443` | 业务只需提供域名与上游端口；443 被备案拦截，客户端一律用 8443 |
| 备份 | 见 `docs/postgres.md` | 新业务上线时必须确认已进备份范围 |

## 二、业务需要满足什么

| 约束 | 为什么 |
|---|---|
| 容器内监听固定端口（当前约定 `8000`） | 宿主机端口映射与 Caddy 上游按此配置 |
| 暴露 `GET /healthz`，返回 200 | 编排放置健康检查与监控依赖它；**未配置凭据时也应 200**（用字段表达降级） |
| 有状态数据只写 `/data` | 卷由 infra 提供；写在别处等于没有备份 |
| `/mcp` 自己做令牌校验 | 反代不做鉴权，这是安全边界（见 `docs/edge.md` 第三节；业务仓库 `docs/auth-contract.md`） |
| 业务 compose 加入 `pandabase` 网络 | 否则连不上 PG |
| 只读平台值，不改 infra 文件 | 依赖方向单向：infra 不引用业务，业务不引用 infra |

## 三、业务侧需要配置的值（照抄即可）

```yaml
# 业务自己的 compose 或 .env，变量名由业务决定；这里只是值
MYBMO_AUTH_MODE: oidc
CASDOOR_ISSUER: https://auth.pandabase.top:8443
MYBMO_JWKS_URL: https://auth.pandabase.top:8443/.well-known/jwks
MYBMO_OIDC_AUDIENCE: <该业务在 Casdoor 的 client_id>
MYBMO_RESOURCE_URL: https://<该业务域名>:8443
MYBMO_DATABASE_URL: postgresql://<app>:<pwd>@pandabase-postgres:5432/<app>
```

> 刻意不统一变量名：改名要求业务停机 + 改代码 + 改文档，而对通用性零收益。
> 真正的解耦点是「infra 给值、业务自己取名」。

## 四、升级与变更顺序

1. **业务镜像升级**：业务仓库自己 `up -d --build`，infra 不参与
2. **infra 配置变更**（新增 client_id 白名单、DSN 轮换）：先改 infra，再通知业务重启
3. **PG 大版本升级**：infra 主导，需全业务停机窗口，顺序见 `docs/postgres.md`
4. **issuer 变更**：默认不允许。真要变更按「新建 IdP + 全业务迁移」处理，不是配置改动。
   唯一已批准的例外是 2026-11-14 加端口 `:8443`（未备案域名 443 被 RST），
   过程见 `docs/decisions/0005-alt-port-tls.md`——这种变更**不会**有第二次免费机会，
   再来一次就是全体客户端重新接入。

## 五、故障时的责任划分

| 现象 | 先查谁 |
|---|---|
| 业务 401 / 403 | 业务侧令牌校验；再看 Casdoor 的 scope 与 client_id |
| 业务 502 | 业务容器是否在跑；宿主 Caddy 到上游端口是否通 |
| 业务连不上库 | `pandabase` 网络、角色权限、DSN |
| 所有业务同时 401 | Casdoor 是否可达、JWKS 是否可拉 |
| 证书过期 | 宿主 Caddy（`journalctl -u caddy`） |
