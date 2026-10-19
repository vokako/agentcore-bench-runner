# 多 harness 对比（同一镜像，换 harness）

镜像只做一次：任务镜像里不预装任何 agent，agent 在每个 trial 开始时由 `install.sh` 装进沙箱。
所以同一个 ECR 镜像可以换不同 harness 运行，只需换 `runner/harnesses/<name>/{install.sh,agent.sh}`。

## 计划矩阵（数据集：benchmarks/tb2-fast30.txt，模式：microVM）

| harness | 模型（Bedrock global 跨区域推理配置文件） |
|---|---|
| claude-code | `global.anthropic.claude-haiku-5-5` |
| claude-code | `global.anthropic.claude-sonnet-5-5` |
| codex | `global.openai.gpt-6.1-sol` |
| kiro-cli | Kiro 自带模型（经 auto-agent-eval 适配） |

模型 ID 已用 `aws bedrock list-inference-profiles`（us-east-2）确认存在，2026-10-09。

## 状态

- [x] harness 可插拔（`--harness` / `--model`，`runner/harnesses/<name>/`）
- [ ] claude-code × haiku-5-5
- [ ] claude-code × sonnet-5-5
- [ ] codex × gpt-6.1-sol
- [ ] kiro-cli
- [x] summary.json 记录 token / 成本（harness 写 /bench/usage.json；Claude Code 的 cost_usd 是它自带价目表的估算，需按 Bedrock 价格复核）

## Codex 接 Bedrock 的实测（2026-10-09）

Codex 的 `amazon-bedrock` provider 走的是 Bedrock Mantle 的 OpenAI Responses 接口
（`https://bedrock-mantle.<region>.api.aws/openai/v1/responses`），不是 Bedrock Runtime 的 Converse。

| 检查 | 结果 |
|---|---|
| 执行角色权限 | 需要 `bedrock-mantle:CreateInference`（`iam/execution-role-mantle.json`），缺失时 403 |
| `global.openai.gpt-6.1-sol` | 在 Mantle 上 404（us-east-1 / us-east-2 / us-west-2 都不认）。global 推理配置文件只在 Bedrock Runtime 上存在 |
| `openai.gpt-6.1-sol` | us-east-1 返回 200；us-east-2、us-west-2 返回 404 |
| `openai.gpt-5.6-sol` | us-east-2 返回 200 |

结论：Codex 不能用 global 跨区域推理配置文件调 gpt-6.1-sol，只能在 us-east-1 用 `openai.gpt-6.1-sol`。
沙箱在 us-east-2，Codex 跨区域调 us-east-1 的 Mantle。探测脚本：`scripts/mantle_models.py <region> <model-id>...`。

## 公平比较的统一配置

| 维度 | Claude Code | Codex | kiro-cli |
|---|---|---|---|
| 模型 | `--model`（Bedrock global 推理配置文件） | `--model` + `--model-region us-east-1`（Mantle） | `--model`（Kiro 模型 ID，如 `claude-sonnet-5.5`） |
| effort | `claude --effort <e>` | `config.toml: model_reasoning_effort` | `kiro-cli chat --effort <e>` |
| 统一取值 | `--effort high` | `--effort high` | `--effort high` |
| 用量来源 | `--output-format json` 的 `usage` / `modelUsage` | `codex exec --json` 的 `turn.completed.usage` | `--output-format stream-json` 的 `metadata.meteringUsage`（credit） |
| 成本 | 按 Bedrock 价目表 × token 重算（不用 harness 自报） | 同左 | credit × $0.02（Kiro 套餐内单价） |

Kiro 本机实测（2026-10-09，`claude-sonnet-5.5 --effort high`，一句话回复）：stream-json 返回
`meteringUsage: [{value: 0.489, unit: credit}]`，`reasoning.effort: high`。Kiro 不输出 token 数，只有 credit。

所有 harness 的 `summary.json.usage` 都带 `effort` 字段，记录实际使用的取值。

### 更正：GPT-6.1 Sol 的 global 推理在 bedrock-runtime 上可用

模型卡 [GPT-6.1 Sol](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-1-sol.html)：
`bedrock-runtime` 支持 Responses API，OpenAI 兼容地址为 `https://bedrock-runtime.{region}.amazonaws.com/openai/v1`，
global 推理 ID 为 `global.openai.gpt-6.1-sol`。`bedrock-mantle` 只支持 us-east-1 的 in-region，价格比 Global CRIS 高 10%。
上面"Codex 不能用 global"的结论只对 Mantle 成立。下一步：让 Codex 指向 bedrock-runtime 的 OpenAI 兼容地址。
