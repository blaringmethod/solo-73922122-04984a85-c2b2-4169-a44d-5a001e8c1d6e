# Traffic PITR Recovery API（交通数仓误删恢复）

路口分钟计数被值班员误删后，需要从**物理备份 + WAL 归档**把删除前的记录找回来补数；
恢复期间主库采集不中断。本服务在启动时对主库做一次 `pg_basebackup` 物理基准备份，
主库持续归档 WAL；用户在任意时刻创建**命名恢复点**，只有当该点所需的 WAL 全部归档
后才允许选择它恢复；每次恢复都从基准备份**重建一个全新的隔离只读副本**，重放 WAL 到
目标恢复点即停，供查询补数。

## WAL 归档的 gzip 滚动（新旧段共存）

归档卷随采集只增不减，新 WAL 段默认以 **gzip** 归档，旧的未压缩段原样保留、继续可读。
归档与恢复两端的格式约定：

- **归档端（主库 `archive_command` → `db/archive/archive-dispatcher.sh`）**
  - 写入格式由共享卷上的控制文件 `/wal_archive/.archive_mode` 决定（`gzip` 默认 /
    `plain`），可经 `PUT /archive/mode` 运行期切换；**已归档段不受切换影响**。
  - 段先写到 `*.partial-<pid>` 临时文件，只有 `gzip -t` 容器校验 **且** 全量解压后与
    源段逐字节 `cmp` 一致，才通过同卷硬链接**原子发布**为正式的 `<段名>.gz`；
    压缩被 kill / 掉电时只留下 `*.partial-*`，不会产生可被恢复误读的正式文件。
  - 同名重试（Postgres 归档失败后会重试）绝不覆盖已完成段：重新校验已有归档，
    校验通过即成功返回；校验失败或源段不一致则明确报错、保留原文件。
  - 旧的未压缩段（裸 `<段名>`）始终优先；同一基名已存在 plain 段时不会再生成 gzip 副本。
- **恢复端（副本 `restore_command` → `api/app/restore-wal.sh`）**
  - 逐段选择读取方式：裸段名存在则原始 `cp`；否则找 `<段名>.gz` 用 `gzip -dc`
    **流式解压**到目标路径。一个恢复点跨越格式切换点时，plain 段与 gzip 段
    在同一次重放中透明混用。
  - 缺段（两种格式都不存在）、gzip CRC/流损坏、解压输出长度不对，都以非零退出
    并清掉半成品目标文件；API 的恢复预检（`_preflight_archive`）还会在启动副本前
    先逐段确认存在性并对每个 gzip 跑 `gzip -t`，把「缺段 / 损坏压缩包」直接写成
    恢复任务上的明确错误。
- **用量核对（`GET /archive/usage`）**：分别返回 plain / gzip 两种格式的**文件数、
  逻辑字节（gzip 取 ISIZE 解压后大小）与实际占用字节（`st_blocks`×512）**，并汇总
  总占用与相对未压缩的节省字节；中断残留的 `*.partial-*` 单列为 `partial_files`，
  不计入正式归档。

## 架构

```
┌──────────────┐   WAL 归档(archive_command)   ┌───────────────┐
│  db (主库)    │ ───────────────────────────▶ │  wal_archive  │
│  traffic 库   │                              │  (共享卷)      │
│  单表:        │ ◀──────── pg_basebackup ───┐ │               │
│  traffic_     │                            │ │               │
│  minute_      │        ┌───────────────────┴─┴─────────────┐ │
│  counts       │        │  api (FastAPI)                    │ │
└──────────────┘        │  · 启动时物理基准备份 (/backups)    │ │
       ▲                │  · 恢复点就绪检查 (WAL 连续性)       │ │
       │ 主库采集不中断   │  · 恢复执行器: 每次从基准备份重建    │ │
       └────────────────│    隔离副本, 重放 WAL 到恢复点暂停   │ │
                        │    (/recovery_work/rN, 只读热备)     │ │
                        └─────────────────────────────────────┘ │
```

- **db**：`postgres:16`，开启 `archive_mode=on`、`archive_timeout=10s`，WAL 经
  `archive-dispatcher.sh` 归档到共享卷（新段 gzip，可经 `/archive/mode` 切换）。
  源库只有一张业务表 `traffic_minute_counts(intersection_id, minute_utc, vehicle_count)`。
- **api**：`postgres:16` 镜像 + FastAPI。启动时执行 `pg_basebackup -X stream` 建立物理
  基准备份；恢复时把基准备份复制到全新目录，配置 `restore_command`（`restore-wal.sh`，
  逐段 plain 复制或流式 gunzip）+ `recovery_target_name` +
  `recovery_target_action=pause`，以热备只读方式启动在
  独立端口（容器内 127.0.0.1:55433）。
- API 自身的台账（恢复点、恢复任务）存在独立 SQLite（api_state 卷），**不污染源库**，
  源库始终只有一张业务表。

## 快速开始

```bash
docker compose up --build
# 等待 api 就绪后:
# 1) 打开演示入口 http://localhost:8000/docs （Swagger UI，根路径 / 会重定向到这里）
# 2) 或跑一键演示脚本（需要 curl 和 jq）:
./scripts/demo.sh
```

演示脚本完整走一遍：先以 plain 归档模拟「旧格式」采集 → 切换到 gzip → 创建恢复点
`before_delete`（其 WAL 范围横跨两种格式）→ 等待 WAL 归档齐全 → 模拟误删最近 10 分钟 →
主库继续以 gzip 写入新路口数据 → 发起 PITR 恢复（逐段混用 plain/gzip 重放）→
从只读副本查回被删记录 → 断言副本不含恢复点之后的提交、主库数据未受影响，
最后核对 `/archive/usage` 的双格式计数与实际占用、节省字节。

## API 一览（详见 /docs）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 服务与主库连通性 |
| GET | `/backup` | 启动基准备份状态（running/ready/failed + 错误） |
| GET | `/archive/usage` | 归档用量：plain/gzip 各自文件数、逻辑字节、**实际占用字节**，总占用与节省字节；中断残留单列 `partial_files` |
| GET | `/archive/mode` | 主库当前归档格式（gzip/plain） |
| PUT | `/archive/mode` | 切换**后续**归档格式 `{"mode":"gzip"\|"plain"}`，已归档段不动 |
| POST | `/demo/generate` | 模拟采集：生成 路口×分钟 计数（可指定前缀/数量） |
| POST | `/demo/delete` | 模拟误删：删除最近 N 分钟数据 |
| GET | `/primary/traffic` | 查主库当前数据（证明主库一直在采集） |
| GET | `/demo/overview` | 主库数据、备份、归档用量、恢复点、恢复任务总览 |
| POST | `/restore-points?name=...` | 创建命名恢复点（`pg_create_restore_point` + 强制切 WAL） |
| GET | `/restore-points` | 恢复点列表：`pending`（WAL 未齐）/ `ready`（可选）/ `expired`（早于基准备份） |
| POST | `/recoveries` | 发起恢复 `{"restore_point": "name"}`，202 异步任务；同一时刻只允许一项在途 |
| GET | `/recoveries` / `/recoveries/{id}` | 恢复任务状态：running/success/failed/superseded + 错误详情 |
| GET | `/recoveries/current` | 当前对外服务的恢复（无则 404） |
| GET | `/replica/traffic` | 查询已恢复只读副本（未就绪/已失败返回 409） |

## 恢复语义（对照需求）

- **启动即备份**：api 启动时后台执行 `pg_basebackup -X stream`（失败自动重试 10 次，
  状态见 `/backup`）；主库 WAL 由 `archive_command` 持续归档。
- **恢复点门控**：创建恢复点时记录其 LSN 并 `pg_switch_wal()`；后台任务持续校验
  「基准备份结束 LSN → 恢复点 LSN」之间每一个 WAL 段都已在归档目录中（裸段或 `.gz`
  任一形式存在即可，`*.partial-*` 不算），齐全才置 `ready`；未就绪的点发起恢复返回
  409。早于基准备份重做起点的点标记 `expired`。
- **跨格式重放**：恢复预检逐段确认归档存在并对 gzip 段执行 `gzip -t`；副本
  `restore_command` 对每个请求段按「plain 优先、否则流式 gunzip」选择读法，因此
  跨越 gzip 切换点的恢复点无需人工干预即可重放；缺段、损坏 gzip、解压长度不符都
  显式失败（任务 `failed` 带原因），不会开放残缺副本。
- **物理恢复**：每次恢复都 `cp` 基准备份到全新目录 `recovery_work/rN`，写
  `recovery.signal` 与 PITR 配置后启动独立 postgres——不是逻辑留史/影子表。
- **到达目标才报成功**：轮询副本直到 `pg_last_wal_replay_lsn() >= 目标 LSN`，
  并对业务表执行一次真实查询确认可查询，才置 `success` 并开放查询。
- **失败即报、不留残缺**：缺 WAL（`restore_command` 失败 → postgres FATAL）、
  恢复进程退出（pg_ctl 探活 + 后台看门狗每 3s 巡检）都会把任务置 `failed` 并记录
  postgres 日志尾部；失败任务的目录被清理，**不开放残缺副本，也不回退到上一次副本**
  （新恢复启动时会先退役并删除旧副本）。重试 = 再 POST 一次。
- **单一在途**：存在 running 任务时再发起返回 409。
- **不混数据**：新恢复启动即退役（停止+删除）旧副本并清空服务指针；每次恢复都是
  基准备份的全新拷贝，先后两个恢复点互不干扰。
- **主库不阻塞**：恢复只读归档卷与基准备份，对主库零写入、零锁。

## 环境变量（api 服务）

| 变量 | 默认 | 说明 |
|---|---|---|
| `PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE` | db/5432/postgres/postgres/traffic | 主库连接 |
| `REPLICA_PORT` | 55433 | 副本监听端口（容器内 127.0.0.1） |
| `RECOVERY_TIMEOUT_SEC` | 180 | 等待重放到目标点的超时 |
| `REPLICA_RUN_AS` | postgres | 副本进程运行用户（容器内 root 经 gosu 降权；本地裸跑可置空） |
| `BACKUP_ON_STARTUP` | 1 | 启动时是否做基准备份（预置备份的测试场景可置 0） |
| `WAL_ARCHIVE_DIR/BACKUP_DIR/RECOVERY_ROOT/STATE_DB` | /wal_archive /backups/base /recovery_work /state/api.db | 存储路径 |
| `RESTORE_SCRIPT` | 镜像内 `/app/restore-wal.sh` | 副本 `restore_command` 调用的混合格式取数脚本 |

## 自测脚本（无需 Docker / Postgres，沙箱可跑）

| 脚本 | 覆盖内容 |
|---|---|
| `scripts/test-archive.sh` | 归档/恢复两个 shell 脚本的 30 项断言：gzip 完整写入+校验后发布、同名重试不覆盖、压缩中断只留 partial、重试补齐、plain 旧段可读、跨格式逐段恢复、缺段/损坏 gzip 显式失败 |
| `scripts/test_archive_py.py` | `app/archive.py` 与恢复预检的 9 项单元测试：格式分类、混合格式查找与 plain 优先、双格式计数/逻辑与实际占用字节、partial 单列、模式原子切换、缺段与损坏 gzip 的明确报错 |

```bash
./scripts/test-archive.sh
python3 -I scripts/test_archive_py.py
```

## 已验证 / 未验证（诚实清单）

交付前在本沙箱用 Python 3.11 标准库 + 真实 bash/gzip（16 MiB 仿真 WAL 段）运行验证。
**注意：本沙箱内核级禁止一切跨进程信号**（kill/pidfd 均 EPERM，实测 `kill -9` 一个
gzip 子进程返回 Permission denied），且无 Docker、无 pip、无 PostgreSQL 二进制；因此
涉及真实数据库与容器联调的部分无法在本环境执行。

已验证（真实运行）：

- ✅ **gzip 归档全流程**（`test-archive.sh`，30 项）：完整写入后 `gzip -t` + 全量
  解压 `cmp` 双校验才发布正式 `.gz`；16 MiB 段实际压到约 16 KB
- ✅ **压缩中断语义**：以 SIGKILL 等价方式（gzip shim 写一半退出 137）验证中断后
  只有 `*.partial-*`、无正式文件、恢复端不会误读；重试后正式段发布且内容逐字节一致
- ✅ **同名重试不覆盖**：已完成段重试走重新校验、inode 不变；源段被篡改/已有 gzip
  损坏时明确非零退出且不覆盖原文件
- ✅ **旧 plain 段保持可读**：plain 模式逐字节归档；同名幂等；已存在 plain 段时
  切回 gzip 不会产生重复格式
- ✅ **混合格式恢复取数**（真实 16 MiB 段）：`restore-wal.sh` 对 plain 段原始 `cp`、
  对 gzip 段 `gzip -dc` 流式解压，连续跨格式取数均与源段逐字节一致
- ✅ **缺段 / 损坏压缩包显式失败**：缺段、截断 gzip（`unexpected end of file`）、
  plain 段长度不符均非零退出并删除半成品目标；Python 预检单测覆盖同样两类失败，
  错误信息明确包含段名与原因
- ✅ **归档用量 API**（`test_archive_py.py`，9 项）：双格式文件数、逻辑字节（gzip
  取 ISIZE）、实际占用字节（`st_blocks`）、节省字节、`partial_files` 单列；实测
  16 MiB gzip 段逻辑 16,777,216 / 占用 32,768，节省统计与分项之和严格相等
- ✅ **模式切换 API**：`PUT/GET /archive/mode` 原子改写控制文件、无临时文件残留、
  非法值拒绝；dispatcher 每次调用读取、默认 gzip
- ✅ 路由注册（含新增 3 个归档端点）、全部 Python/bash 语法、compose YAML 结构、
  demo.sh 与两个自测脚本语法

未能在本环境验证（沙箱无 Docker/Postgres/信号所致，逻辑已按 Docker 场景设计并走查）：

- ⚠️ `docker compose up --build` 整体构建联调与 `/docs` Swagger 实操（沙箱无 docker）；
  已修复基线中归档卷可能 root 属主导致主库无法写入的问题（新增
  `entrypoint-fixperms.sh` 在官方 entrypoint 的 root 阶段 `chown` 归档卷）
- ⚠️ 真实 PostgreSQL 端到端：基准备份成功路径、plain→gzip 切换后实际归档出两种段、
  恢复点横跨格式切换的真实重放闭环（沙箱无 PG 二进制且禁止 checkpoint/热备信号，
  与上一版基线相同的环境限制）；恢复语义本身沿用上一版已在单用户模式验证过的机制，
  本次仅把 `restore_command` 从 `cp` 换成等价的混合格式脚本
- ⚠️ 对**真实正在运行的 gzip 进程**发 SIGKILL（沙箱 EPERM）；已用退出码 137 的
  gzip shim 复现完全相同的中断后果（shell 重定向留下半截 partial、无正式文件）

## 限制

- 单 api 进程、单副本端口：同一时刻一个恢复、一个副本（需求即如此）。
- 基准备份为启动时一份；api 重启会重取备份，此前创建的恢复点会标记 `expired`。
- 恢复点名称唯一（重复创建返回 409）；WAL 归档卷只增不减，演示规模无清理策略；
  gzip 中断残留的 `*.partial-*` 可在 `/archive/usage` 看到，重新归档同名段时会自动清掉。
- 无认证鉴权，仅限内网演示。
