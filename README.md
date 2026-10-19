# AgentCore Bench Runner

在 Amazon Bedrock AgentCore 上运行 [Harbor](https://docs.harborframework.com) 格式的 agent 评测任务（如 Terminal-Bench 2.0、Terminal-Bench-Science）。

客户端只做两件事：**创建评测任务**、**拉取结果**。一次评测（trial）从运行 agent、等待它结束、用任务自带测试判分、上传结果，到释放沙箱，全部在 AgentCore Runtime 的会话内完成，不依赖其他调度服务。

仓库内置三个 harness：**Claude Code**、**Codex**、**kiro-cli**，可以用同一批任务镜像比较不同 agent + 模型的通过率、成本和耗时。每个 harness 由两个脚本接入，新增 agent 不需要改流程，见[更换 agent](#更换-agent)。完整的对比结果和复现步骤见[复现 harness 对比](#复现-harness-对比tb2-50-个任务)。

## 架构

![架构](docs/images/architecture.png)

| 编号 | 谁执行 | 做什么 |
|---|---|---|
| ⓪ | 客户端 | 准备工作，每个任务做一次：用 `scripts/build_*.sh` 按通用模板构建镜像并推送到 ECR，之后的 trial 复用 |
| ① | 客户端 | 把任务的 `tests/` 打包上传到 S3 `inputs/<task>/<run-id>/tests.tgz` |
| ② | 客户端 | 确保沙箱存在：同一镜像复用同一个 Harness / Agent Runtime，首次使用时创建 |
| ③ | 客户端 | 在新会话里安装 agent，然后送入 `trial.sh` 并后台启动。**调用立即返回，客户端到此结束** |
| ④ | 沙箱 | agent 退出后，`trial.sh` 从 S3 取回测试包 |
| ⑤ | 沙箱 | 执行 `tests/test.sh` 得到 `reward.txt`，把 reward、ctrf、日志、`summary.json` 写到 S3 `runs/<task>/<run-id>/` |
| ⑥ | 沙箱 | 调用 `StopRuntimeSession` 停止自己的会话，沙箱释放 |
| ⑦ | 客户端 | 任何时候读取 `runs/<task>/<run-id>/summary.json` 获得结果 |

## 生命周期

![生命周期](docs/images/lifecycle.png)

- **客户端不参与中间过程**：submit 返回后，不需要保持连接，也不轮询沙箱。
- **agent 结束即判分**：`trial.sh` 以前台方式运行 agent，进程退出后直接进入判分，不依赖外部判断。
- **测试在 agent 结束后才进入沙箱**：测试包放在 S3，agent 运行期间不在沙箱内。
- **`summary.json` 是完成标记**：它最后写入，出现即表示 trial 结束；`status.json` 记录当前阶段（agent / verifier / uploading）。
- **沙箱自行释放**：结果写完后 `trial.sh` 停止自己的会话。会话的空闲超时设为 8 小时，只作为兜底（原因见 [limitations](docs/limitations.md#会话与空闲超时)）。

## 两种运行模式

![两种运行模式](docs/images/modes.png)

| | microVM 模式 | Runtime Instances 模式 |
|---|---|---|
| 计算 | AgentCore 托管 microVM | 你账户里的 EC2（capacity provider） |
| 沙箱资源 | `Harness` | `Agent Runtime` + `capacityProviderConfiguration` |
| 镜像 | 用任务 `environment/Dockerfile` 原样构建 arm64 镜像 | 用任务 `docker_image` 原始镜像，套通用模板 `adapter/` |
| 规格 | 固定 2 vCPU / 8 GB | 实例族自选（CPU、内存、GPU、磁盘） |
| 创建时间（沙箱定义，每个镜像一次） | 约 150 s | 约 10 s |
| 冷启动时间（每个 trial 的新会话） | 约 12 s | 约 43 s（c7i.xlarge，需先起一台 EC2） |
| 适合 | 轻量任务 | 重任务、x86 专属依赖、官方预构建镜像 |

两种模式的客户端命令、`trial.sh`、结果格式完全相同，只有 `--mode` 和镜像不同。

创建时间只在某个镜像第一次使用时发生一次，之后的 trial 复用沙箱定义；每个 trial 都要付的是冷启动时间。所以按单个 trial 算，microVM 启动更快。两项都是实测，细节见 [limitations](docs/limitations.md#时间开销实测)。

### 选择模式

![选择模式](docs/images/choose-mode.png)

细节见 [docs/modes.md](docs/modes.md)。

## 任务格式（Harbor）

一个任务是一个目录，分两组文件：

```
<task>/
├── instruction.md      题目，交给 agent
├── task.toml           超时、资源、网络、镜像（docker_image）等配置
├── environment/        agent 的运行环境：Dockerfile 及其构建上下文
├── tests/              判分：test.sh 写出 /logs/verifier/reward.txt（或 reward.json）
└── solution/           参考解（本工具不使用）
```

本工具读取 `instruction.md`、`task.toml`（`[agent].timeout_sec`、`[verifier].timeout_sec`、工作目录）和 `tests/`，任务文件不做任何修改。

## 镜像处理（模板化，不按任务手改）

| 模式 | 命令 | 做了什么 |
|---|---|---|
| microVM | `scripts/build_microvm.sh <task-dir> <ecr-repo>` | 对 `environment/` 执行 `docker build --platform linux/arm64`，Dockerfile 原样使用 |
| Instances | `scripts/build_instances.sh <docker_image> <ecr-repo>` | `FROM <docker_image>`，只加保活入口（`/opt/bench/`），镜像里缺 curl 时补装 curl 和 ca-certificates |
| Instances，镜像超过上限 | `scripts/build_split.sh <docker_image> <ecr-repo> <s3-prefix> <dir>...` | 大目录移到 S3，瘦身镜像套同一模板；`trial.sh` 在 agent 启动前放回原路径。见 [docs/large-images.md](docs/large-images.md) |

同一条命令适用于所有任务。

## 批量运行

```bash
scripts/build_all.sh microvm <ecr-registry> tasks/*        # 在 arm64 机器上构建全部任务
python runner/batch.py --mode microvm --image '<ecr-registry>/bench/{task}:arm64' \
                       --jobs 10 --out out-microvm tasks/*
```

构建或运行失败的任务会记录原因并跳过，整批继续。输出 `results.jsonl`（每个任务一行）和 `summary.md`（reward、耗时、磁盘余量、错误）。Terminal-Bench 2.0 全量 89 个任务的实测见 [docs/batch-tests.md](docs/batch-tests.md)。

## 快速开始

前置条件：Python 3.11+、Docker、已配置的 AWS 凭证（`aws sts get-caller-identity` 能返回身份）。

```bash
pip install -r requirements.txt                 # boto3 >= 1.43.98

# 1. 执行角色（沙箱内使用）：把策略里的 <results-bucket> / <prefix> / <account-id> 替换掉
aws iam create-role --role-name bench-runner-exec \
    --assume-role-policy-document file://iam/execution-role-trust.json
aws iam put-role-policy --role-name bench-runner-exec --policy-name bench-runner \
    --policy-document file://iam/execution-role-policy.json

# 2. 配置
cp config.example.json config.json              # 区域、角色 ARN、模型、结果 bucket
                                                # Instances 模式另需 capacity_provider_arn

# 3. 构建镜像
scripts/build_microvm.sh tasks/fix-git <ecr>/bench/fix-git                          # microVM（arm64 机器上）
scripts/build_instances.sh alexgshaw/fix-git:20251031 <ecr>/bench/fix-git          # Instances

# 4. 创建评测任务（返回 run_id 后客户端即结束）
python runner/bench.py submit --mode microvm   --task tasks/fix-git --image <ecr>/bench/fix-git:arm64
python runner/bench.py submit --mode instances --task tasks/fix-git --image <ecr>/bench/fix-git:instances

# 5. 拉取结果（--wait 可选：最多等待 N 秒）
python runner/bench.py results <run-id> --wait 1800

# 不再使用时删除本工具创建的沙箱资源
python runner/bench.py cleanup
```

批量评测就是对多个任务依次 `submit`，每个 trial 在各自的会话里并行运行。

Instances 模式需要预先创建 capacity provider（实例族、子网、安全组、根卷大小），参见 [Runtime Instances 文档](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-instances.html)。

## 结果

```
s3://<bucket>/<prefix>/runs/<task>/<run-id>/
  submitted.json   提交信息：模式、镜像及其大小、沙箱（是否复用）、会话、沙箱准备与安装耗时
  status.json      当前阶段
  agent.log        agent 输出
  verifier.log     tests/test.sh 输出
  reward.txt       Harbor 分数（或 reward.json）
  ctrf.json        测试明细（任务提供时）
  trial.log        trial.sh 自身日志
  summary.json     最终摘要：reward、各阶段退出码与耗时（含拆分构建镜像的恢复耗时）；最后写入
```

## 复现 harness 对比（TB2 50 个任务）

用 15 个 agent + 模型组合，各跑 low / medium / high 三档 effort，覆盖 50 个 Terminal-Bench 2.0 任务。结果见 [docs/results/tb2-50-matrix.md](docs/results/tb2-50-matrix.md)。

| 文件 | 内容 |
|---|---|
| `benchmarks/tb2-fast30.txt` | 30 个较快的任务（选法见 [docs/tb2-fast30.md](docs/tb2-fast30.md)） |
| `benchmarks/tb2-hard20.txt` | 20 个较难、能拉开差距的任务 |
| `benchmarks/matrix.txt` | 要跑的 agent + 模型组合，一行一个 |
| `benchmarks/pricing.json` | 计算成本用的单价（每 1M token；kiro 每 credit），带来源 |

### 1. 准备（一次）

在[快速开始](#快速开始)的基础上：

```bash
scripts/fetch_tb2.sh                     # 拉取 TB2 到 vendor/terminal-bench-2（固定 commit 2fd12b8）

# 构建 50 个任务的 arm64 镜像（在 arm64 机器上，如 Graviton EC2）
scripts/build_all.sh microvm <account>.dkr.ecr.<region>.amazonaws.com \
    $(grep -hv '^#' benchmarks/tb2-fast30.txt benchmarks/tb2-hard20.txt | sed 's|^|vendor/terminal-bench-2/|')
```

`config.json` 的 `image_template` 填 `<account>.dkr.ecr.<region>.amazonaws.com/bench/{task}:arm64`。

按要跑的 harness 给执行角色追加权限：

| harness | 额外需要 |
|---|---|
| Claude Code | 无（`iam/execution-role-policy.json` 已含 Bedrock InvokeModel） |
| Codex | `iam/execution-role-codex-bearer.json`：沙箱用执行角色签发短期 Bedrock API key，调用 bedrock-runtime 的 OpenAI 兼容接口 |
| kiro-cli | `iam/execution-role-kiro-secret.json`，并把 Kiro API key 存进 Secrets Manager：`aws secretsmanager create-secret --name bench/kiro-api-key --secret-string "$KIRO_API_KEY"` |
| Kimi Code | 同 Codex（`iam/execution-role-codex-bearer.json`），走 bedrock-runtime 的 OpenAI 兼容接口；另需离线包，见下 |
| Qoder CN / CodeBuddy 国内版 | `iam/execution-role-cli-secrets.json`，key 分别存为 `bench/qoder-api-key` 和 `bench/codebuddy-api-key`；另需离线包，见下 |

还要在 Bedrock 控制台开通要用的模型。

**固定版本。** 每个 harness 的 `install.sh` 默认装发布结果用的版本，不装 latest：

| harness | 默认版本 | 覆盖用的环境变量 | 来源 |
|---|---|---|---|
| Claude Code | 2.1.296 | `BENCH_CLAUDE_VERSION` | npm |
| Codex | 0.162.1 | `BENCH_CODEX_VERSION` | npm |
| kiro-cli | 2.29.0 | `BENCH_KIRO_VERSION`（`latest` 取最新） | 官方 release zip |
| Kimi Code | 2.1.1 | `BENCH_KIMI_VERSION` | 离线包 |
| Qoder CN | 1.1.70 | `BENCH_QODER_VERSION` | 离线包 |
| CodeBuddy | 2.164.0 | `BENCH_CODEBUDDY_VERSION` | 离线包 |

**离线包（Kimi Code、Qoder CN、CodeBuddy）。** 沙箱从结果 bucket 下载离线包，校验同目录的 `SHA256SUMS` 后安装。用仓库里提交的锁文件（`runner/harnesses/<harness>/bundle/<version>/package-lock.json`）构建并上传一次：

```bash
scripts/build_harness_bundle.sh kimi-code 2.1.1           # 纯 JS，x64 / arm64 通用
scripts/build_harness_bundle.sh qoder-cn 1.1.70 arm64     # microVM 是 arm64
scripts/build_harness_bundle.sh codebuddy 2.164.0 arm64
```

脚本用 `npm ci` 按锁文件安装，每个依赖的版本和 integrity 都固定。重建出来的包和发布结果用的包逐文件一致，只有 tar 本身的时间戳不同，所以 sha256 会和 `SHA256SUMS.original` 里记录的原值不一样。上传位置是 `s3://<results_bucket>/<results_prefix>/artifacts/`，需要 Node 22.19 以上和 AWS CLI。

### 2. 跑

```bash
scripts/run_suite.sh smoke-cc claude-code global.anthropic.claude-haiku-5-5 low 1 <(echo fix-git)   # 先试跑 1 个任务
python runner/bench.py results --wait 600 $(head -1 runs/smoke-cc/results.jsonl | python -c 'import json,sys;print(json.load(sys.stdin)["run_id"])')

scripts/sweep.sh                          # 全部：15 组 x 3 档 effort x 2 个任务列表 = 90 个 run
ONLY='^cc-' scripts/sweep.sh              # 只跑 Claude Code 的几行
```

- 每个 run 写到 `runs/<fast30|hard20>-<name>-<effort>/`，在后台运行，日志在 `batch.log`。
- `sweep.sh` 会跳过已经存在的 run，所以中断后再跑一次就能补齐缺口。
- 并发：每个 run 默认 5 个 trial。全部同时开时有 450 个 trial 并发，kiro-cli 会被限流，详见下一步。

Kimi K3 的四个 harness 对比不全在 `sweep.sh` 里，单独这样跑（`<list>` 是 `benchmarks/tb2-fast30.txt` 或 `benchmarks/tb2-hard20.txt`）：

```bash
ONLY='^kimicode-k3$' scripts/sweep.sh                                             # Kimi Code + Bedrock K3，low/medium/high
for e in low high max; do scripts/run_suite.sh fast30-kiro-kimik3-$e kiro-cli kimi-k3 $e 3 benchmarks/tb2-fast30.txt; done   # kiro 的 K3 没有 medium
scripts/run_suite.sh fast30-qodercn-kimik3-default qoder-cn Kimi-K3 default 3 benchmarks/tb2-fast30.txt     # Qoder 对 K3 不接受 effort
scripts/run_suite.sh fast30-codebuddy-kimik3-medium codebuddy kimi-k3-2 medium 3 benchmarks/tb2-fast30.txt
```

Qoder 和 CodeBuddy 按 credit 计费，Fast30 每题约 39 credit，Hard20 约 100 credit，跑之前确认账号余额。额度用完后的 trial 会被 `scripts/classify_trials.py` 归为 `not_run`，看板不计分。

### 3. 处理限流，出结果

```bash
python scripts/throttles.py runs/*-kiro-* --json runs/throttles.json       # 找出被限流的 trial
python scripts/retry_throttled.py launch runs/throttles.json --jobs 1      # 只重跑这些任务
python scripts/retry_throttled.py merge  runs/throttles.json               # 跑完后替换回原结果

python scripts/matrix_report.py --out docs/results/my-matrix.md            # 50 个任务的总表
python scripts/refusals.py runs/hard20-*                                   # 查看模型安全拒答
```

要在网页里看和筛选结果，可以用 [auto-agent-eval](https://github.com/vokako/auto-agent-eval) 的看板，它的 `scripts/sync_agentcore_jobs.py` 会读取这里的 `runs/`。

## 更换 agent

`trial.sh` 与 agent 无关。每个 harness 是 `runner/harnesses/<name>/` 下的两个脚本，用 `--harness <name>` 选择：

| 文件 | 约定 |
|---|---|
| `install.sh` | 在沙箱内安装 agent，接在公共的 `runner/install.sh`（Node.js 与 AWS SDK）后面执行，成功时退出码为 0 |
| `agent.sh` | 读取 `/bench/instruction.md`，**前台**运行 agent，返回 agent 的退出码；可把用量写到 `/bench/usage.json`，会并入 `summary.json` |

沙箱内可用的环境变量：`BENCH_MODEL`（`--model`）、`BENCH_EFFORT`（`--effort`）、`BENCH_MODEL_REGION`（`--model-region`）、`BENCH_REGION`。三个内置 harness 的模型、effort 和用量统计方式见 [docs/harnesses.md](docs/harnesses.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/modes.md](docs/modes.md) | 怎么选 microVM 还是 Instances |
| [docs/limitations.md](docs/limitations.md) | 限制与配额（实测 / 文档分别标注） |
| [docs/large-images.md](docs/large-images.md) | 超过镜像上限时的拆分构建方案 |
| [docs/test-plan.md](docs/test-plan.md) | 测试矩阵与结果汇总 |
| [docs/size-and-storage-tests.md](docs/size-and-storage-tests.md) | 镜像大小与存储的专项测试 |
| [docs/batch-tests.md](docs/batch-tests.md) | Terminal-Bench 2.0 全量批量测试 |
| [docs/harnesses.md](docs/harnesses.md) | 三个 harness 的模型、effort、用量与成本口径 |
| [docs/results/tb2-50-matrix.md](docs/results/tb2-50-matrix.md) | 50 个任务的 harness x 模型 x effort 对比 |
| [docs/results/](docs/results/) | 批量测试每个任务的逐条记录 |

## 目录

| 路径 | 内容 |
|---|---|
| `runner/bench.py` | 客户端：`submit` / `results` / `cleanup` |
| `runner/trial.sh` | 沙箱内的 trial 控制脚本 |
| `runner/install.sh` | 沙箱内的公共安装：Node.js 与 AWS SDK |
| `runner/harnesses/` | 每个 harness 的 `install.sh` + `agent.sh` + `usage.sh`：`claude-code` / `codex` / `kiro-cli` / `kimi-code` / `qoder-cn` / `codebuddy`；离线包的锁文件在 `<harness>/bundle/<version>/` |
| `runner/aws.mjs` | 沙箱内 S3 读写与停止会话（凭证来自执行角色） |
| `runner/batch.py` | 批量运行：一次提交多个任务，限制同时在跑的数量，从 S3 汇总结果 |
| `adapter/` | 两种模式共用的镜像模板（microVM 只用其 `tools` 阶段） |
| `scripts/` | 镜像构建（`build_*.sh`）；拉取 TB2（`fetch_tb2.sh`）；运行对比（`run_suite.sh`、`sweep.sh`）；限流重跑（`throttles.py`、`retry_throttled.py`）；出结果（`matrix_report.py`、`compare_runs.py`、`task_matrix.py`、`refusals.py`） |
| `benchmarks/` | 任务列表、对比矩阵、价格表 |
| `tasks/` | 示例任务，原样取自 [Terminal-Bench 2.0](https://github.com/laude-institute/terminal-bench-2)（Apache-2.0，见 `tasks/LICENSE`）：`fix-git` / `log-summary-date-ranges` / `openssl-selfsigned-cert` |
| `iam/` | 执行角色与调用方的权限策略 |
| `docs/` | 模式选择、限制、大镜像处理、测试结果 |
