# pandabase-infra

pandabase 系列业务的共享底座：域名与 TLS、身份（Casdoor）、数据库（PostgreSQL）、容器网络、
备份与升级。**这里不放业务逻辑**——业务以「镜像 + 契约」接入，编排留在各自仓库。

规模假设：一台 2C2G 的轻量机器、个位数业务、单人维护。所有设计取舍都以这个规模为前提，
换规模时先改 ADR 再改代码（见 `docs/decisions/`）。

## 快速开始（首次搭一套）

```bash
# 1. 共享网络（业务 compose 用它，见 docs/contract.md）
bash scripts/bootstrap-network.sh

# 2. 数据库
cp deploy/postgres/.env.example deploy/postgres/.env     # 填 pandabase_admin 口令
docker compose -f deploy/postgres/docker-compose.yml up -d
# 新卷由镜像的 entrypoint 按 POSTGRES_USER 建好运维角色；
# 若是从别处迁移来的旧数据卷（里面有别的超级用户），才需要：
#   bash scripts/pg-provision.sh --init --as <现有超级用户>

# 3. 身份
cp deploy/casdoor/.env.example deploy/casdoor/.env       # 填库口令与 issuer
docker compose -f deploy/casdoor/docker-compose.yml up -d
curl -fsS https://auth.pandabase.top/.well-known/openid-configuration | head -c 80

# 4. 运维控制台（可选）。Casdoor 侧要先建 Application/Site/Permission，见 docs/identity.md 第七节
bash scripts/pg-provision.sh reader casdoor              # 建只读角色 dbx_read，打印一次 DSN
cp deploy/dbx/.env.example deploy/dbx/.env               # 填 DBX_PASSWORD
docker compose -f deploy/dbx/docker-compose.yml up -d
```

宿主 Caddy 的站点块见 `deploy/caddy-site.caddyfile`——追加到 `/etc/caddy/Caddyfile` 再 reload，
不要另起容器（见 `docs/edge.md`）。

## 目录

| 路径 | 内容 |
|---|---|
| `deploy/postgres/` | 平台 PostgreSQL（独立 compose project） |
| `deploy/casdoor/` | 身份服务，连平台 PG 的 `casdoor` 库 |
| `deploy/dbx/` | 运维控制台 DBX（只读看库；公网入口先过 Casdoor 闸门） |
| `deploy/Caddyfile`、`deploy/caddy-site.caddyfile` | 专用宿主机（容器版）与共享宿主机（片段）两份配置 |
| `scripts/` | 建网、建库建角色、备份、项目改名迁移 |
| `docs/decisions/` | ADR：仓库边界、PG 平台化、身份 |
| `docs/contract.md` | **唯一的耦合面**：业务接进来需要知道的一切 |
| `docs/postgres.md`、`docs/identity.md`、`docs/edge.md` | 三套组件的运维细节 |
| `docs/workload-onboarding.md` | 新业务接入检查单 |

## 与业务仓库的关系

```
pandabase-infra  ──提供──▶  网络 · 库/角色/DSN · Casdoor 应用 · TLS · 备份
       ▲                            │
       └────── 不依赖业务代码 ───────┘
                                    ▼
                          业务仓库（自带 compose 与镜像）
```

- infra **不引用**任何业务的文件路径、镜像名、端口、卷名
- 业务仓库**不引用** infra 的 `deploy/` 或文档路径；它只需要 `docs/contract.md` 里公布的值
- 唯一例外：`scripts/` 里的一次性迁移脚本会操作业务容器，跑完即废弃

## 现状（2026-11-08）

| 项 | 值 |
|---|---|
| 机器 | 49.232.229.71，2C2G，Ubuntu |
| PostgreSQL | 17.11（`postgres:17-bookworm`），project `pandabase`，容器 `pandabase-postgres`，卷 `pandabase_pgdata`（48.7 MB），库 `casdoor` 10 MB |
| 角色 | `pandabase_admin`（运维超管）/ `casdoor_app`（服务，非超管）/ `casdoor`（bootstrap，已 `NOLOGIN` 封存） |
| Casdoor | `casbin/casdoor:latest`，project `pandabase-casdoor`，issuer `https://auth.pandabase.top` |
| 边缘 | 宿主 Caddy（systemd），80/443；`baiduads` → `127.0.0.1:8000`，`auth` → `127.0.0.1:8001`，`dbx` → `127.0.0.1:8002`（先过 Casdoor 闸门） |
| 业务 | `mybmo-mcp`，仓库独立，模式 `oidc`，容器未被本次迁移重启 |
| 迁移 | 2026-11-08 20:01 完成，旧 project `mybmo-casdoor` 与旧卷保留至 11-15；备份在 `backups/rename-2026-11-08-200101/` |
| 业务 | `mybmo-mcp`，仓库独立，模式 `oidc` |
| 待办 | PG 仍在旧 project `mybmo-casdoor` 下，改名与降权见 `docs/postgres.md` 的迁移章节 |

## 不做

不做业务编排与审批、不在反向代理做鉴权（唯一例外是 DBX 控制台的**纯闸门**，
见 ADR 0004）、不引 K8s、不提供 DCR、不做跨业务共库共表。
理由分别见 ADR 0001/0003/0004 与业务仓库的 ADR 0003。
