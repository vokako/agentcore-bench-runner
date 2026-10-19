# 同一镜像换 harness：TB2-Fast30 对比（2026-10-09）

## 结论

任务镜像只构建一次，里面不预装 agent；每个 trial 开始时由 `runner/harnesses/<name>/install.sh` 把 harness 装进沙箱。
同一批 30 个 microVM 镜像（`bench/{task}:arm64`）分别跑了 Claude Code、Codex 和 kiro-cli，镜像没有改动。

## 设置

- 数据集：`benchmarks/tb2-fast30.txt`（30 个 TB2 任务），模式 microVM（us-east-2），每组跑 1 轮。
- effort：五组都显式设为 `high`（`--effort high`），实际值记录在每个 trial 的 `summary.json`。
- Claude Code 和 Codex 的模型都走 Bedrock global 跨区域推理配置文件；kiro-cli 用 Kiro 自己的模型 ID。
- 成本：Claude Code 和 Codex 用 `benchmarks/pricing.json` 按 token 重算（`scripts/compare_runs.py`），不用 harness 自报的数字。
  kiro-cli 只报告 credit（stream-json 里的 `meteringUsage`），按 $0.02/credit（套餐内折算价）换算成美元，括号里是 credit 数。

## 结果

| harness | 模型 | 通过 | agent 耗时中位数 | agent 总耗时 | 输出 token | 缓存读 | 缓存写 | 成本 |
|---|---|---|---|---|---|---|---|---|
| Claude Code | `global.anthropic.claude-haiku-5-5` | 24/30 | 62 s | 59.3 min | 481,950 | 7,612,595 | 812,680 | $0.42 |
| Claude Code | `global.anthropic.claude-sonnet-5-5` | 27/30 | 28 s | 23.7 min | 110,532 | 3,432,018 | 389,403 | $2.42 |
| Claude Code | `global.anthropic.claude-opus-5-5` | 27/30 | 84 s | 59.6 min | 147,799 | 3,552,558 | 394,595 | $5.64 |
| Codex | `global.openai.gpt-6.1-sol` | 28/30 | 74 s | 49.3 min | 157,287 | 6,337,827 | 0 | $3.56 |
| kiro-cli | `claude-sonnet-5.5` | 27/30 | 28 s | 23.7 min | 不报告 | 不报告 | 不报告 | $0.57（28.6 credit） |

未通过的任务：

| 组合 | 未通过 |
|---|---|
| Claude Code + Haiku 5.5 | build-pmars, torch-pipeline-parallelism, db-wal-recovery, chess-best-move, model-extraction-relu-logits, adaptive-rejection-sampler |
| Claude Code + Sonnet 5.5 | raman-fitting, chess-best-move, adaptive-rejection-sampler |
| Claude Code + Opus 5.5 | password-recovery, chess-best-move, adaptive-rejection-sampler |
| Codex + GPT-6.1 Sol | build-pmars, sanitize-git-repo |
| kiro-cli + claude-sonnet-5.5 | torch-pipeline-parallelism, chess-best-move, adaptive-rejection-sampler |

原始结果：`runs/fast30-cc-haiku55-high`、`runs/fast30-cc-sonnet55-high`、`runs/fast30-cc-opus55-high`、
`runs/fast30-codex-gpt61sol-global-high`、`runs/fast30-kiro-sonnet55-high`。

## 读结果时要注意

- **只跑了 1 轮。** 30 个任务里一个任务就是 3.3 个百分点；同一配置的另一轮（未显式设 effort）Sonnet 5.5 是 28/30、Haiku 5.5 是 24/30。27/30 和 28/30 之间的差距不能当作 harness 之间的差距。
- **kiro-cli 和 Claude Code + Sonnet 5.5 的总耗时都是 23.7 min，是巧合。** 两组的中位数分别是 27.5 s 和 28.5 s，逐任务耗时不同。
- **kiro-cli 的成本不能和 token 成本直接比。** credit 是 Kiro 订阅的计价单位，不对应 Bedrock 按 token 的价格；表里的美元数是 credit × $0.02（Kiro 套餐内单价，Pro 为 $20 / 1,000 credit）；加购或超额 credit 是 $0.04，成本会翻倍。
- **token 口径不同。** Claude Code 的 input 只算未缓存部分；Codex 的 input 包含缓存部分（`cached_input_tokens` 是它的子集），重算成本时已扣除。Codex 不报告缓存写，按 0 计。
- **价格来源。** Claude 来自 AWS Price List API（us-east-2 Global 行）；GPT-6.1 Sol 来自 Bedrock 模型卡（Global CRIS）。Sonnet 5.5 的缓存读在 10 月 7 日降价 50%，价目表里的 $0.10/1M 是哪一档还没确认。
- **Haiku 5.5 的 effort。** Claude Code 文档的 effort 支持表里没有 Haiku，`--effort high` 可能没有生效。
- **Codex 的两条路径。** `global.openai.gpt-6.1-sol` 只在 bedrock-runtime 的 OpenAI 兼容接口上可用，沙箱用执行角色签发短期 Bedrock API key 调用；in-region 的 `openai.gpt-6.1-sol` 走 Mantle（us-east-1，贵 10%），那一组是 23/30、$3.35。

## kiro-cli

- harness：`runner/harnesses/kiro-cli/`，安装官方 aarch64 zip（glibc < 2.34 时用 musl 版），参数 `--model`、`--effort`。
- 用量：`--output-format stream-json` 里每轮的 `meteringUsage`（credit），事件里的 `reasoning.effort` 记录实际 effort（本次全部是 high）。
- 认证：Secrets Manager 里的 `bench/kiro-api-key`，沙箱用执行角色读取（权限示例 `iam/execution-role-kiro-secret.json`），key 不经过客户端。

## Effort 档位对比（2026-10-09 第二批）

每个组合在 low / medium / high 三档各跑 1 轮 TB2-Fast30，全部 microVM、同一批镜像。完整表格：
`docs/results/fast30-effort-sweep.md`。kiro-cli 的成本按 $0.02/credit 换算。

| 组合 | low | medium | high |
|---|---|---|---|
| Claude Code + Haiku 5.5 | 22 · $0.23 | 25 · $0.30 | 24 · $0.42 |
| Claude Code + Sonnet 5.5 | 26 · $1.63 | 28 · $1.69 | 27 · $2.42 |
| Claude Code + Opus 5.5 | 27 · $3.17 | 26 · $5.29 | 27 · $5.64 |
| Codex + GPT-6.1 Sol（global） | 29 · $1.71 | 25 · $2.72 | 28 · $3.56 |
| kiro-cli + claude-sonnet-5.5 | 28 · $0.37 | 27 · $0.40 | 27 · $0.57 |
| kiro-cli + claude-opus-5.5 | 26 · $0.59 | 27 · $1.07 | 26 · $1.34 |
| kiro-cli + gpt-5.6-sol | 25 · $4.23 | 27 · $11.02 | 30 · $12.45 |

Fast30 上大多数组合在 26-30 之间，差 1-3 个任务，单轮区分不了。effort 稳定改变的是耗时和成本：
从 low 到 high，成本大约增加 1.5-3 倍，通过率没有一致变化。只有 kiro-cli + gpt-5.6-sol 呈现单调上升（25 → 27 → 30）。

## TB2-Hard20

Fast30 拉不开差距，所以另选了 20 个更难的 TB2 任务（`benchmarks/tb2-hard20.txt`）：
以往 microVM 上没有环境问题、但 agent 失败过或两轮结果不一致的任务。完整表格：
`docs/results/hard20-compare.md`，逐任务结果 `docs/results/hard20-matrix.md`（R = 模型安全拒答）。

| 组合 | effort | 通过 | 拒答 | agent 中位数 | 成本 |
|---|---|---|---|---|---|
| Codex + GPT-6.1 Sol | high | 15/20 | 0 | 166 s | $5.09 |
| Codex + GPT-6.1 Sol | low | 14/20 | 0 | 66 s | $1.78 |
| Claude Code + Sonnet 5.5 | high | 13/20 | 2 | 78 s | $2.50 |
| Claude Code + Sonnet 5.5 | low | 11/20 | 2 | 58 s | $1.56 |
| Claude Code + Haiku 5.5 | high | 12/20 | 0 | 182 s | $0.61 |
| Claude Code + Opus 5.5 | high | 10/20 | 6 | 152 s | $7.33 |
| kiro-cli + claude-sonnet-5.5 | high | 12/20 | 2 | 86 s | $0.76 |
| kiro-cli + claude-opus-5.5 | high | 11/20 | 6 | 174 s | $1.41 |
| kiro-cli + gpt-5.6-sol | high | 11/20 | 1 | 272 s | $6.89 |
| kiro-cli + gpt-5.6-sol | low | 12/20 | 1 | 78 s | $4.23 |

- **安全拒答影响很大。** Opus 5.5 在 Claude Code 和 kiro-cli 里都拒答了同样 6 个任务（破解、XSS 过滤绕过、DNA/蛋白设计），
  Sonnet 5.5 拒答 2 个，kiro-cli 里的 gpt-5.6-sol 拒答 1 个；Haiku 和 Codex 没有拒答。Fast30 里 Opus 也在所有 6 轮拒答 `password-recovery`。
  拒答由 `scripts/refusals.py` / `scripts/task_matrix.py --refusals` 从 agent.log 识别，按失败计入通过数。
- **扣除拒答后**，Opus 在剩下 14 个任务上通过 10（Claude Code）和 11（kiro-cli），比例并不低。
- **同模型换 harness 差别小。** Sonnet 5.5：Claude Code 13，kiro-cli 12；Opus 5.5：10 和 11。
- **effort 在难题上也没有拉开通过率**（Codex 15 vs 14，Sonnet 13 vs 11，gpt-5.6-sol 11 vs 12），但 high 的耗时是 low 的 1.3-3.5 倍。
- **仍然只有 1 轮。** 20 个任务一个任务是 5 个百分点，2 个任务以内的差距不能下结论。
