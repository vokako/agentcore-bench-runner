# 限制与配额

标注：**实测** = 在 us-east-1 / us-east-2 实际观测；**文档** = AWS 官方文档。

## 镜像

| 项 | 值 | 说明 |
|---|---|---|
| 镜像大小上限（压缩后） | 账户配额。本账号实测：microVM 约 3 GB（2.88 GB 可运行，3.09 GB 不可）；Instances 2 GB（默认，可申请调到 3 GB） | 换模式不能绕开 |
| 超限时的表现 | microVM：Harness 创建成功，**会话无输出、无错误、无日志**；Instances：`CreateAgentRuntime` 报 `ServiceQuotaExceededException: maxImageSizeMb` | 实测。`bench.py` 提交前按 `max_image_mb` 检查 |
| 镜像解压后大小 | microVM：必须放得进约 8.8 GiB 的根文件系统，否则同样静默失败；Instances：占用根卷可写空间 | 实测：rootfs 约 8,972 MiB；解压后 4.4 GB 时剩 972 MiB，5.47 GB 时剩 0，放不下 agent。建议 microVM 镜像解压后不超过 4 GB。另有一个 4.14 GB 的真实镜像静默失败，原因未查明（见 [batch-tests.md](batch-tests.md#24-microvm-解压后大小的补充测试)） |
| microVM 架构 | **仅 arm64** | 实测：amd64 镜像报 `Architecture incompatible ... Supported platforms: [arm64]` |
| Instances 架构 | `LINUX_X86_64` / `LINUX_ARM64` | 文档：capacity provider `operatingSystem` |

- 超过上限的镜像走**拆分构建**：大目录移到 S3（`scripts/build_split.sh`，已实测）或 EBS 快照（设计），运行时放回原路径，用 Instances 模式运行。见 [large-images.md](large-images.md)。

## 计算与存储

| 项 | microVM | Instances |
|---|---|---|
| vCPU / 内存 | 固定 2 vCPU / 8 GB（文档，不可调） | 取决于所选实例族 |
| 可写空间 | rootfs 共约 8.8 GiB，基础镜像下约 4.7 GiB 可用，镜像每多 1 GiB 可写空间少 1 GiB（实测） | `rootVolume.freeSpaceGiB` 2-65,000 GiB，另有最多 5 个 EBS 卷（文档）；本次测试的 capacity provider 根卷可用约 20 GiB，镜像内容也占用这部分空间（实测）。配置方法见 [modes.md](modes.md#可写空间大的任务) |
| 会话最长寿命 | `maxLifetime` 最长 8 h（文档） | 同左 |

| `/dev/shm` | 64 MiB（实测） | 64 MiB（实测） |
| 磁盘写满时的错误 | `Input/output error`，随后根文件系统变为**只读**（EROFS）（实测） | `No space left on device`（实测） |

- 磁盘写满只影响当前会话，同一沙箱的下一个会话是干净的（实测）。`trial.sh` 预留 64 MiB，任务写满磁盘时仍能写出 `summary.json` 并停止会话；写满期间产生的日志可能为空。
- 需要大 `/dev/shm` 的任务（如 PyTorch DataLoader 多进程）可能失败。没有找到调大它的配置项。

任务声明的资源（`task.toml` 的 `cpus` / `memory_mb` / `storage_mb`）超出 microVM 规格时，用 Instances 模式。Agent 超时（`[agent].timeout_sec`）加判分时间超过 8 小时的任务无法在一个会话内完成。

## 批量运行中确认的限制（实测，Terminal-Bench 2.0 全量）

详见 [batch-tests.md](batch-tests.md)。

| 项 | 说明 |
|---|---|
| 端口 8080 | 两种模式都已被占用：microVM 由运行时自带的服务占用，Instances 由健康检查端点（`adapter/entry.sh`）占用。需要监听 8080 的任务无法原样运行 |
| capacity provider 的 `idleInstanceTimeout` | 按"实例上没有调用"计时，trial 期间客户端不发调用。该值小于 trial 时长时，实例会被回收，trial 丢失。`bench.py` 在该值小于 trial 超时时拒绝提交 |
| 控制面限流 | 多个 trial 同时提交时，`ListAgentRuntimes` 等 list API 会被限流。`bench.py` 使用 adaptive 重试 |
| Instances 下需要 capability 的操作 | `chroot`，以及判分时 dpkg 装包过程中的 `chgrp` 会失败。`build_all.sh` 从 `tests/test.sh` 提取包名并在构建时预装，但并非所有写法都能提取到 |
| trial 丢失 | 两轮全量运行中出现 3 次（共约 350 个 trial），日志中没有找到原因。由心跳判定为 lost 并记录，重跑即可 |
| 结果波动 | 同一任务两次运行的 reward 可能不同，比较时应多跑几次 |

## 会话与空闲超时

- **空闲计时从最后一次调用算起，不看沙箱里是否有进程在运行**（实测）。`idleRuntimeSessionTimeout=60` 时，后台进程在客户端停止调用后被回收，4 分钟后的 S3 标记没有写出；设为 900 时同一进程正常完成。
- 因此 `bench.py` 把空闲超时和最长寿命都设为 8 小时，trial 期间客户端无需任何调用。正常结束时 `trial.sh` 主动停止会话，不会等到超时。若 `trial.sh` 异常退出，会话最迟在 8 小时后回收。
- 会话状态无法通过 API 查询（没有 GetRuntimeSession）。trial 进度以 S3 上的 `status.json` / `summary.json` 为准。
- 不要复用 `runtimeSessionId`：停止后再用同一 id 调用会得到一个全新的空沙箱，不报错（实测）。`bench.py` 每个 trial 都用新 id。

## 判分

- 判分在 **agent 所在的同一个沙箱**中进行，对应 Harbor 的默认模式（`environment_mode = "shared"`）。测试在 agent 退出后才从 S3 取回。
- Harbor 的独立判分模式（`environment_mode = "separate"` 或 `[verifier.environment]`：在另一个断网沙箱中判分，只复制 `artifacts` 声明的产出物）**尚未支持**。Terminal-Bench-Science 的任务全部使用独立判分模式，在本工具上运行时判分环境与官方不同，结果不应作为官方排行榜提交。
- **docker-compose 多容器任务不支持**，运行前应从任务列表中排除，并在结果中注明（例如"70 个任务中运行了 65 个"）。详见下一节。

## docker-compose 多容器任务

`environment/` 下带 `docker-compose.yaml`、声明了除 `main` 以外的服务的任务，本工具不运行。

- **范围**：Terminal-Bench 2.0 的 89 个任务中没有这类任务（有 2 个任务的 `task.toml` 带 `custom_docker_compose = true`，但 compose 配置已迁入 Dockerfile，按单容器正常运行）。Terminal-Bench-Science 的 70 个任务中有 5 个：`inverse-lithography`、`protein-active-learning`、`longitudinal-clinical-agent`、`noisy-blackbox-optimization`、`tamp-skill-planning`。
- **这类任务的形态**：除 agent 所在的 `main` 容器外，还有一个或多个 sidecar 服务（如模拟器、评估器、实验装置），agent 只能通过 HTTP 调用，不能读取其实现。部分 sidecar 有状态，例如只允许提交一次。
- **为什么不支持**：一个 AgentCore 会话只运行一个容器，沙箱内也不能再运行容器（Instances 模式没有 Linux capability）。
  - 把 sidecar 并入 `main` 容器，agent 就能直接读到它的实现和隐藏参数，评测失去意义。
  - 把 sidecar 放到另一个会话，会话之间没有直接的网络连通，只能经 `InvokeAgentRuntime` 转发。这需要端口适配、名称解析和转发代理，改动了任务的运行环境，风险和维护成本都较高。
- **如需运行**：在支持 docker compose 的环境中运行这些任务，例如 Harbor 自带的 `docker` 或 `ec2` 环境。

## Instances 模式的执行环境

命令以 root（uid 0）执行，但**没有任何 Linux capability**（`CapEff` / `CapBnd` 均为 0），并启用 seccomp（实测）。影响和处理：

| 现象 | 原因 | 处理 |
|---|---|---|
| 判分脚本 `apt-get install` 报 `setgroups` / `seteuid` / `Permission denied` | apt 需要切换到 `_apt` 用户（CAP_SETUID），并写入 `_apt` 所属目录 | `adapter/` 在**构建时**补装 curl 和 ca-certificates；其他包用 `APT_PACKAGES` 追加 |
| `tar: Cannot change ownership ... Operation not permitted` | root 无 CAP_CHOWN，无法还原归档属主 | 沙箱内设置 `TAR_OPTIONS=--no-same-owner` |

仍然做不到的：改文件属主为其他用户（`chown user`）、切换用户、挂载、改内核参数。依赖这些操作的任务在 Instances 模式下会失败。microVM 模式没有这些限制（实测）。

## 时间开销（实测）

分两类时间：**创建时间**是为某个镜像创建沙箱定义，每个镜像只发生一次；**冷启动时间**是每个 trial 新开一个会话、到第一条命令返回的时间，每个 trial 都要付。

| 阶段 | microVM | Instances（c7i.xlarge） |
|---|---|---|
| 创建时间：沙箱定义到 READY（每个镜像一次） | 约 150 s（`CreateHarness`） | 约 10 s（`CreateAgentRuntime`，只是注册） |
| 复用已有沙箱定义 | 约 1 s | 约 2 s |
| 冷启动时间：新会话到第一条命令返回 | 11.7-14.0 s（3 次） | 43.2-43.8 s（3 次） |
| 安装 Node + Claude Code + AWS SDK（含冷启动） | 12-15 s | 约 50 s |

冷启动的测法：对已有沙箱定义，用新的会话 ID 执行一条 `cat /proc/uptime`，计时到命令返回，每种模式连续 3 次。Instances 的 3 次里，容器看到的系统运行时间都只有约 35 s，说明每个新会话都落在一台刚启动的 EC2 上。上一个会话停止后，它的实例没有被下一个会话复用，即使 capacity provider 的空闲超时是 900 s。之前的 PoC 中也见过约 2 min 的冷启动。换实例类型后时间会不同，未测。

## Agent 与凭证

- Claude Code 在 root 下会拒绝 `bypassPermissions`，设置 `IS_SANDBOX=1` 后可以运行（实测）。不要降权到普通用户：需要修改系统目录的任务会因此失败，看起来像模型能力不足（实测）。
- 会话内 AWS 相关环境变量全为空，SDK 通过 IMDSv2 取得执行角色凭证（实测）。沙箱内所有进程（包括 agent）共享同一执行角色，所以执行角色只授予：模型调用、拉取镜像、读 `inputs/`、写 `runs/`、停止会话（见 [iam/execution-role-policy.json](../iam/execution-role-policy.json)）。

## Usage accounting when the agent is cut off

`trial.sh` runs `harnesses/<h>/usage.sh` after the agent however it ended, so a timeout kill no longer
skips the usage summary. `usage_source` in `summary.json` says where the numbers came from.

| Harness | What survives a timeout | How |
|---|---|---|
| Claude Code | Tokens | `--output-format stream-json` plus Claude Code's session transcript. The stream's `output_tokens` is the count at the start of each message (2-8), so the final count is taken from the transcript (`usage_source: stream+transcript`). In a 90 s probe the stream said 37 output tokens and the transcript 2866. |
| Codex | Tokens | The last cumulative `token_count` in Codex's rollout file (`usage_source: rollout`), when no `turn.completed` event was written. |
| kiro-cli | Nothing | kiro-cli reports credits (`metadata.meteringUsage`) only when a turn ends, and a headless run is one turn. SIGINT makes it exit without reporting, and neither its session files nor its logs record credits. Probed with 30 s timeouts. |

For kiro-cli the credits of a timed-out trial cannot be recovered, so a job's cost is a lower bound when
it contains such trials. Estimating from context size was tried and rejected: on completed trials the
held-out error of the summed estimate was 8-50% by model, and 20-90% per trial.

`scripts/recompute_usage.py` re-reads the event streams of existing kiro-cli runs and fills in credits
that are in the stream but were never summarized.

Each trial also uploads `session-logs.tgz` (the agent's own session files) and `usage.json`.
