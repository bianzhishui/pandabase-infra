# 平台 PostgreSQL

一个实例、N 个库。实例地址 `pandabase-postgres:5432`（只在 `pandabase` 网络内）。
宿主另有 `127.0.0.1:5432` 的回环发布，只给 SSH 隧道和本地 DBX 用——**公网不可达**，
因为 PG 自身 `ssl=off`，一旦绑到 `0.0.0.0` 就是明文对全网开放。
版本钉在 `postgres:17-bookworm`。

## 一、角色模型

| 角色 | 用途 | 属性 | 口令存放 |
|---|---|---|---|
| `pandabase_admin` | 建库建角色、备份、升级 | `LOGIN SUPERUSER CREATEDB CREATEROLE`（平台唯一可登录的超级用户，**仅运维使用**） | `deploy/postgres/.env` |
| `casdoor_app` | Casdoor 服务自己 | `LOGIN`，owner of `casdoor` 库及其对象，`CONNECTION LIMIT 20` | `deploy/casdoor/.env` |
| `casdoor` | initdb 创建的 bootstrap 超级用户 | **已封存**：`NOLOGIN` + `CONNECTION LIMIT 0`（PG 不允许摘掉它的 SUPERUSER，见下） | 已从 Casdoor 配置中移除 |
| `<app>` | 每个业务一个 | `LOGIN`，owner of 自己的库，`CONNECTION LIMIT 20` | infra 生成后一次性交付业务方 |
| `dbx_read` | DBX 控制台（运维 UI） | `LOGIN`，按库只授 `SELECT`，`CONNECTION LIMIT 5` | `scripts/pg-provision.sh reader <库>` 一次性打印 |

> **bootstrap 超级用户不能降权**。PostgreSQL 会直接拒绝：
> `permission denied to alter role / DETAIL: The bootstrap superuser must have the SUPERUSER attribute`。
> 迁移时因此改为「新建 `casdoor_app` 承载服务 + 逐对象转移属主 + 封存 bootstrap 角色」。
> 封存不等于删除：它的属性仍在，但 `NOLOGIN` + 连接上限 0 使其无法被使用。

三条硬规则：

1. **没有任何业务角色是 superuser**。这条是平台化的前提：一个业务被攻破不能波及别人的库。
2. 业务角色**只**拥有自己的库，不跨库授权。需要跨库读写在设计上就不允许。
3. 建库建角色只走 `scripts/pg-provision.sh`，不手工敲 SQL——否则权限模型会在某次赶时间时破口。

`dbx_read` 是唯一一个「按库只读」角色：`bash scripts/pg-provision.sh reader <库>`
只给该库的 `SELECT`，并设置默认权限覆盖今后新建的表；要再看一个库就再跑一次，
不跨库授权。DBX 的部署与使用见 `docs/dbx.md`。

## 二、库清单

| 库 | 属主 | 用途 | 当前大小 |
|---|---|---|---|
| `casdoor` | `casdoor` | Casdoor 的账号、应用、证书、scope | 10 MB |
| `postgres` | `pandabase_admin` | 维护库 | 7.5 MB |

新业务接入时由 `pg-provision.sh` 追加一行，并同步登记到 `docs/workload-onboarding.md` 的清单里。

## 三、备份

```bash
bash scripts/pg-backup.sh                 # 产物在 backups/<YYYY-MM-DD>/
```

内容：`globals.sql`（角色与权限）+ 每个非模板库一份 `<db>.dump`（`pg_dump -Fc`）。
脚本会遍历数据目录里所有非模板库，**新增业务自动进备份**，不需要改脚本。

校验（每次备份后脚本自动做）：

```bash
docker run --rm -v "$PWD/backups/<日期>":/b postgres:17-bookworm pg_restore -l /b/casdoor.dump | head
```

恢复单个库（**会覆盖目标库现有数据**）：

```bash
docker exec -i pandabase-postgres pg_restore -U pandabase_admin -d <db> --clean --if-exists \
  < backups/<日期>/<db>.dump
```

恢复角色与权限（新机器重建时）：

```bash
docker exec -i pandabase-postgres psql -U pandabase_admin -d postgres < backups/<日期>/globals.sql
```

保留策略：每日一份，保留 14 天；每周一份归档保留 8 周。备份目录不在容器卷里，
落在宿主 `backups/`（已被 `.gitignore` 排除）。

## 四、升级（大版本）

一次升级影响所有业务，必须留窗口：

1. 确认备份完整（`pg-backup.sh` 全绿）
2. 停所有业务容器 → 停 Casdoor → 停 PG
3. 起新版本空卷 → 按「同大版本拷卷 / 跨大版本 dump+restore」迁移
4. 起 PG → 校验 `PG_VERSION` 与各库表数、行数 → 起 Casdoor → 逐个起业务
5. 旧卷保留 7 天再删

禁止：直接 `docker compose up -d` 换 tag（旧卷的 `PG_VERSION` 会让新版本拒绝启动，业务全挂）。

## 五、连接与资源

- 每个业务角色带 `CONNECTION LIMIT 20`；被拒时报 `too many connections for role`
- 连接池放在业务进程内（`psycopg_pool`），不要在 infra 侧加 PgBouncer——2C2G 上多一层不值得
- 慢查询先用 `pg_stat_activity` 看，不做自动 kill：误杀长事务比慢更危险

## 六、迁移记录：从 Casdoor 的附属库变成平台库

PG 原先在 `mybmo-casdoor` 这个 project 下，角色 `casdoor` 是超级用户。改成平台形态的
一次性迁移由 `scripts/pg-rename-project.sh` 执行（支持 `--dry-run`）：

| 步 | 动作 | 破坏性 |
|---|---|---|
| 0 | 预检：旧卷/旧容器/库与角色清单、磁盘余量 | 只读 |
| 1 | `pg_dump -Fc casdoor` + 整卷 tar 到 `backups/` | 只读 |
| 2 | 停 casdoor、postgres | 停机开始 |
| 3 | 建 `pandabase_pgdata`，解包旧数据（同版本 17，直接拷目录） | 无（旧卷不动） |
| 4 | 起新 project 的 PG，校验 `PG_VERSION=17` | — |
| 5 | 建 `pandabase_admin`；建 `casdoor_app` 并逐对象转移属主（表/序列/视图）+ 库 owner；封存 bootstrap 角色 | 角色切换 |
| 6 | 改 Casdoor 的 `POSTGRES_USER=casdoor_app`，重建容器 | 几秒中断 |
| 7 | 回归：discovery / `application` 行数 / 表数 / 业务 `/healthz` 与 `/mcp` 401 | — |

回滚：**旧栈已于 2026-11-08 22:09 删除**（旧 project、两个旧卷、目录副本都清了），
所以现在不存在「把旧栈起回来」这条退路，只能从备份恢复：

```bash
# 整卷恢复（含 PG 系统目录，等价于回到迁移前）
docker volume create pandabase_pgdata_restore
docker run --rm -v pandabase_pgdata_restore:/to -v "$PWD/backups/rename-2026-11-08-200101":/b \
  alpine sh -c 'cd /to && tar xzf /b/pgdata-16to17.tgz'
# 然后把 deploy/postgres/docker-compose.yml 的卷名临时指向它，起 PG 验证后再换回
```

或者只回滚 `casdoor` 库的数据：`pg_restore -U pandabase_admin -d casdoor --clean --if-exists
< backups/rename-2026-11-08-200101/casdoor.dump`。

迁移期间的影响：Casdoor 不可用（新令牌签不出来）。业务侧已缓存的 JWKS 在 10 分钟内仍能验证
旧令牌；`mcp` 容器本身不依赖 PG，不会被重启。

### 实施记录（2026-11-08 20:01）

第一次执行在「给 bootstrap 超级用户降权」处失败，Casdoor 停了约 90 秒。原因是 PostgreSQL
不允许 `ALTER ROLE casdoor NOSUPERUSER`（见第一节的注）。改走 `casdoor_app` 方案后一次通过：

```text
角色终态
  casdoor         super=t  login=f  connlimit=0     ← bootstrap，封存
  casdoor_app     super=f  login=t  connlimit=20    ← Casdoor 实际使用
  pandabase_admin super=t  login=t  connlimit=-1    ← 运维专用
数据：application=1  tables=50（与迁移前一致），50 张表属主均为 casdoor_app
备份：backups/rename-2026-11-08-200101/（casdoor.dump 140K + 两个旧卷 tar）
```

教训：涉及角色属性的迁移，先在 dry-run 里把「PG 是否允许这条 ALTER」验证掉——
`--dry-run` 目前只读数据，不做权限可行性检查。
