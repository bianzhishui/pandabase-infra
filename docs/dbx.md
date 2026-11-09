# DBX 数据库控制台

运维用，不是业务负载。**只绑回环、不开放公网**，通过 SSH 隧道访问。

```text
你的机器 ──ssh -L 8002──▶ 宿主 127.0.0.1:8002 ──▶ pandabase-dbx:4224
                                                     │
                                                     └─ pandabase-ops 网络 ─▶ pandabase-postgres:5432
```

业务容器在 `pandabase` 网络上，不在 `pandabase-ops`，因此解析不到 DBX。

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

## 三、启停与检查

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

## 四、安全边界

- **不开放公网，也不加 Caddy 站点**。需要「任意浏览器可用」时先看
  [ADR 0004](decisions/0004-dbx-console.md) 的重新评估条件，别直接加站点。
- **反向代不注入身份头**，DBX 也不消费身份头；不存在「伪造头直连回环」的旁路。
- **DBX 只挂 `pandabase-ops`**。不要把它加进 `pandabase` 业务网络。
- **只放只读账号**。不要为了「方便」把 `pandabase_admin` 填进去。
- 卷 `pandabase_dbx_data` 里有连接口令的加密密钥，**不进异地备份**。

## 五、升级

镜像钉在 `t8y2/dbx:0.6.64`。升级按变更做：先改 compose 里的 tag，
在桌面版把常用操作跑一遍，再 `up -d`。回滚就是把 tag 改回去再 `up -d`。

## 六、故障表

| 现象 | 原因 | 处理 |
|---|---|---|
| 浏览器打不开 | 隧道没开 / 端口被占 | 重新开 `ssh -L 8002:...`；`ss -ltnp \| grep 8002` |
| 登录后又回登录页 | 口令错 / `.env` 改了没重建 | 看 `logs dbx`；`up -d` 让新口令生效 |
| 连接报 timeout | DBX 不在 `pandabase-ops` / PG 不在该网络 | `docker network inspect pandabase-ops` 应同时有 PG 与 DBX |
| 连接报密码错 | `dbx_read` 口令被轮换过 | 重新 `ALTER ROLE dbx_read PASSWORD ...`，或重跑 `reader` |
| 看不到新建的表 | 默认权限没覆盖 | 重跑 `bash scripts/pg-provision.sh reader <库>` |
