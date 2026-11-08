# ADR 0002：PostgreSQL 平台化

- 状态：已接受
- 日期：2026-11-08
- 决策者：项目负责人
- 关联：[ADR 0001](0001-repo-boundary.md)、业务仓库 `docs/decisions/0002-tech-stack.md`（D3）

## 背景

PostgreSQL 最初是作为 Casdoor 的附属品起的：与 Casdoor 同一个 compose project
（`name: mybmo-casdoor`）、同一个角色（`POSTGRES_USER=casdoor`，**超级用户**）、
只有 `casdoor` 一个库。

现在 PG 是平台能力：当前业务要用（`MYBMO_DATABASE_URL` 已预留但尚未启用），以后接的业务
也会用。这意味着三件事同时变了——**生命周期**（不能让 Casdoor 重启带走数据库）、
**权限**（不能有一个业务角色持有实例级超级权限）、**备份**（不能只备份 Casdoor 的库）。

## 决策

1. **一个实例，N 个库**。不做每业务一实例：2C2G 上跑不动第二套 PG，而当前数据量只有 10 MB。
2. **PG 独立 compose project**（`pandabase`），不再挂在 Casdoor 下。
   Casdoor 是它的一个客户端，跨 project 用共享网络 `pandabase` 通信。
3. **角色模型**：
   - `pandabase_admin`：平台**唯一的超级用户**，`LOGIN SUPERUSER CREATEDB CREATEROLE`。只给运维脚本用
     （建库建角色、备份、升级），口令只存在于服务器的 `deploy/postgres/.env`，**不注入任何业务容器**。
     需要它是超级用户是因为 `pg_dumpall --globals-only` 要读 `pg_authid`——这是单机单人运维下的
     break-glass 取舍，见「重新评估条件」。
   - 每个业务一个角色，只拥有自己的库，无 `SUPERUSER` / `CREATEDB` / `CREATEROLE`，带 `CONNECTION LIMIT`
   - 现有 `casdoor` 角色**降权**：`NOSUPERUSER NOCREATEDB NOCREATEROLE`，仅保留 `casdoor` 库的 owner
4. **卷名显式固定**（`name: pandabase_pgdata`）。Docker 的卷名由 project 推导，不显式写死就会在
   改 project 名时静默产生一个空卷——表现为「数据没了」。
5. **改名是一次数据迁移**，不是改配置：同大版本之间直接拷贝数据目录（tar），跨大版本才走
   `pg_dump -Fc` + restore。旧卷保留 7 天再删。
6. **备份矩阵按实例组织**：`pg_dumpall --globals-only` + 遍历所有非模板库各一次 `pg_dump -Fc`，
   不再手写库名列表——新增业务自动进备份。
7. **版本钉死、升级留窗口**：`postgres:17-bookworm`，不跟随 `latest`。一次升级影响全部业务，
   必须「备份 → 全业务验证 → 保留回滚路径」。

## 被否决的方案

| 方案 | 否决理由 |
|---|---|
| 每业务一个 PG 实例 | 单机 2C2G，第二套 PG 至少再吃 60 MB 且多一套升级/备份流程 |
| 多业务共用一个库、用 schema 隔离 | 备份与恢复粒度变成整库；一个业务的 DDL 事故会波及其他业务 |
| SQLite / 文件库 | 多进程写、备份一致性、并发刷新锁都不成立（业务侧用 advisory lock 的前提是有 PG） |
| 托管 RDS | 延迟与出网、成本；且当前只需一个库 |
| Casdoor 角色继续做超级用户 | 一个业务被攻破等于整个实例的数据暴露；这是本次要消除的核心风险 |

## 后果

### 正面

- Casdoor 重启/升级不再影响其它业务
- 新增业务只是「建库 + 建角色」，不再复制一套 PG
- 备份自动覆盖所有库

### 负面 / 需要承担

| 风险 | 说明 | 缓解 |
|---|---|---|
| blast radius 变大 | 一次 PG 升级影响所有业务 | 钉版本 + 升级窗口 + 备份演练 |
| 资源竞争 | 一个业务的长事务/连接数会拖慢其它 | 每角色 `CONNECTION LIMIT`，监控连接数与慢查询 |
| 跨 project 无 `depends_on` | 启动顺序不再有编排保证 | `restart: unless-stopped` + 就绪重试；运维文档写明「先 PG 后业务」 |
| 共享网络成为单点 | 网络被删则全部业务失联 | 网络声明为 `external`，由 `scripts/bootstrap-network.sh` 一次性创建，任何 `compose down` 都删不掉 |

## 重新评估条件

- 单个业务数据量 > 10 GB，或需要独立调参/扩展 → 拆实例
- 需要多机或读写分离 → 本 ADR 的单机假设失效
- 业务数 ≥ 5 且互不信任 → 考虑每业务独立实例或独立 schema + 独立角色
