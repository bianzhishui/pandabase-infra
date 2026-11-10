# 新业务接入检查单

按顺序做，每步都有可验证的结果。全部完成后把业务登记到本文末尾的表里。

## 一、确认业务方需要什么

| 问题 | 影响 |
|---|---|
| 域名是什么？ | Caddy 站点块 + 业务侧 `RESOURCE_URL` |
| 容器内监听哪个端口？ | 端口映射与 Caddy 上游；默认约定 8000 |
| 有没有状态？写哪里？ | 需要卷则 infra 提供 `/data`；不需要就别给 |
| 需要哪些 scope？ | 在 Casdoor 应用里登记，并在业务侧校验 |
| 需要数据库吗？ | 需要则走第 2 步 |

## 二、数据库（需要时才做）

```bash
bash scripts/pg-provision.sh <app>          # 幂等：建库 + 建角色 + 打印 DSN
```

产出：库 `<app>`、角色 `<app>`（无 superuser/createdb，`CONNECTION LIMIT 20`）、一条 DSN。
口令只打印一次，交付后由业务方存进自己的 `.env`。

验收：

```bash
docker exec -it pandabase-postgres psql -U pandabase_admin -d postgres -c '\du+'
docker exec -it pandabase-postgres psql -U pandabase_admin -d postgres -c '\l'
```

## 三、身份（每个业务都要）

1. Casdoor 里建 application（Name = 业务名），回调填业务的固定地址
2. 只勾 `authorization_code` + `refresh_token`
3. 登记该业务的 scope（对象数组，见 `docs/identity.md`）
4. 交付 client_id —— 业务方要把它加进 audience 白名单

验收：用该业务的客户端走一次授权码流程能拿到令牌，且令牌 `aud` 等于这个 client_id。

## 四、网络与编排（业务仓库里做）

业务 compose 必须：

```yaml
networks:
  pandabase:
    external: true
```

以及：端口只绑回环、有 `/healthz`、有状态数据写 `/data`、`/mcp` 自己校验令牌。

## 五、边缘

把域名对应的站点块加进宿主 Caddy（见 `docs/edge.md`），`curl -fsS https://<域名>/healthz` 得 200。

## 六、备份与监控登记

- [ ] 数据库已建 → `bash scripts/pg-backup.sh` 跑一次，确认产物里有 `<app>.dump`
- [ ] 有卷 → 卷也进备份（数据卷 tar），并与 PG 备份分开存放
- [ ] `/healthz` 已加入外部监控（或至少验证过 200）
- [ ] 在下面表格里登记

## 七、登记表

| 业务 | 域名 | 端口 | 库/角色 | client_id | 卷 | 接入日期 |
|---|---|---|---|---|---|---|
| `mybmo-mcp` | `baiduads.pandabase.top` | 8000 | 暂无（用文件式 `tenancy.json`） | `709a8e16656a223a1ab7`（应用 `mybmo-mcp`；redirect_uris `http://127.0.0.1:33418/callback`） | `mybmo_data` | 2026-11-08 |
