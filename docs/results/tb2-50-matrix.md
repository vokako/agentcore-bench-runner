# TB2 50 任务：harness x 模型 x effort 对比

50 个任务 = [TB2-Fast30](../tb2-fast30.md)（`benchmarks/tb2-fast30.txt`）+ TB2-Hard20（`benchmarks/tb2-hard20.txt`），全部来自 Terminal-Bench 2.0 commit `2fd12b8`。
15 个 agent + 模型组合，每个跑 low / medium / high 三档 effort，一共 45 行，每行 50 个任务各跑 1 次。

- **运行环境：** AgentCore microVM（2 vCPU / 8 GB），每个 run 同时 5 个 trial。
- **版本：** Claude Code 2.1.296，Codex 0.162.1，kiro-cli 2.29.0。
- **模型调用：** Claude Code 和 Codex 走 Bedrock global 跨区域推理配置文件；kiro-cli 用 Kiro 自己的模型 ID。
- **成本：** Claude Code 和 Codex 按 token 数乘 `benchmarks/pricing.json` 计算；kiro-cli 按 credit × $0.02（套餐内单价）换算。
- **耗时：** 只算 agent 运行时间，不含判分。
- **判分：** 没有 reward 的 trial 算失败。`reshard-c4-data` 在几组里因为磁盘写满没有 reward。
- **复现：** 见 README 的「复现 harness 对比」。表格由 `python scripts/matrix_report.py` 生成。

单次运行的噪声：50 个任务、通过率约 75% 时，两次运行的差距要超过约 8 个任务才算显著。表里相差 1-3 个任务的行不要当成真实差异。

| # | Agent + model | effort | passed | fast30 | hard20 | cost (USD) | agent min / task |
|---|---|---|---|---|---|---|---|
| 1 | codex-gpt61sol (global.openai.gpt-6.1-sol) | low | 43/50 | 29 | 14 | 3.49 | 1.1 |
| 2 | codex-gpt61sol (global.openai.gpt-6.1-sol) | high | 43/50 | 28 | 15 | 8.66 | 2.7 |
| 3 | codex-gpt61sol (global.openai.gpt-6.1-sol) | medium | 41/50 | 25 | 16 | 5.56 | 2.5 |
| 4 | kiro-gpt56sol (gpt-5.6-sol) | high | 41/50 | 30 | 11 | 19.34 | 4.7 |
| 5 | kiro-sonnet55 (claude-sonnet-5.5) | low | 40/50 | 28 | 12 | 0.89 | 2.1 |
| 6 | cc-sonnet55 (global.anthropic.claude-sonnet-5-5) | medium | 40/50 | 28 | 12 | 3.45 | 1.4 |
| 7 | cc-sonnet55 (global.anthropic.claude-sonnet-5-5) | high | 40/50 | 27 | 13 | 4.92 | 1.3 |
| 8 | cc-opus5 (global.anthropic.claude-opus-5) | high | 40/50 | 27 | 13 | 52.34 | 6.6 |
| 9 | kiro-sonnet55 (claude-sonnet-5.5) | high | 39/50 | 27 | 12 | 1.34 | 1.9 |
| 10 | kiro-gpt56terra (gpt-5.6-terra) | high | 39/50 | 23 | 16 | 10.94 | 5.5 |
| 11 | kiro-opus55 (claude-opus-5.5) | medium | 38/50 | 27 | 11 | 2.10 | 4.2 |
| 12 | kiro-opus5 (claude-opus-5) | high | 38/50 | 27 | 11 | 6.41 | 8.7 |
| 13 | kiro-gpt56sol (gpt-5.6-sol) | medium | 38/50 | 27 | 11 | 16.67 | 4.2 |
| 14 | codex-gpt56sol (global.openai.gpt-5.6-sol) | medium | 38/50 | 25 | 13 | 18.06 | 1.8 |
| 15 | kiro-sonnet55 (claude-sonnet-5.5) | medium | 37/50 | 27 | 10 | 0.81 | 2.1 |
| 16 | kiro-opus5 (claude-opus-5) | low | 37/50 | 26 | 11 | 2.70 | 3.6 |
| 17 | kiro-opus55 (claude-opus-5.5) | high | 37/50 | 26 | 11 | 2.75 | 4.4 |
| 18 | cc-sonnet55 (global.anthropic.claude-sonnet-5-5) | low | 37/50 | 26 | 11 | 3.19 | 1.6 |
| 19 | cc-opus55 (global.anthropic.claude-opus-5-5) | low | 37/50 | 27 | 10 | 5.63 | 1.5 |
| 20 | kiro-gpt56sol (gpt-5.6-sol) | low | 37/50 | 25 | 12 | 8.46 | 1.7 |
| 21 | codex-gpt56terra (global.openai.gpt-5.6-terra) | high | 37/50 | 24 | 13 | 9.80 | 1.6 |
| 22 | cc-opus55 (global.anthropic.claude-opus-5-5) | high | 37/50 | 27 | 10 | 12.97 | 4.1 |
| 23 | codex-gpt56sol (global.openai.gpt-5.6-sol) | high | 37/50 | 24 | 13 | 22.33 | 1.8 |
| 24 | cc-haiku55 (global.anthropic.claude-haiku-5-5) | medium | 36/50 | 25 | 11 | 0.75 | 2.9 |
| 25 | cc-haiku55 (global.anthropic.claude-haiku-5-5) | high | 36/50 | 24 | 12 | 1.02 | 3.0 |
| 26 | cc-opus55 (global.anthropic.claude-opus-5-5) | medium | 36/50 | 26 | 10 | 10.25 | 2.1 |
| 27 | cc-opus5 (global.anthropic.claude-opus-5) | low | 36/50 | 24 | 12 | 20.32 | 2.0 |
| 28 | cc-sonnet5 (global.anthropic.claude-sonnet-5) | high | 36/50 | 26 | 10 | 21.23 | 5.4 |
| 29 | kiro-sonnet5 (claude-sonnet-5) | medium | 35/50 | 24 | 11 | 4.55 | 4.9 |
| 30 | kiro-opus55 (claude-opus-5.5) | low | 34/50 | 26 | 8 | 1.12 | 3.4 |
| 31 | kiro-opus5 (claude-opus-5) | medium | 34/50 | 25 | 9 | 4.02 | 5.6 |
| 32 | cc-sonnet5 (global.anthropic.claude-sonnet-5) | low | 34/50 | 24 | 10 | 12.77 | 3.8 |
| 33 | cc-opus5 (global.anthropic.claude-opus-5) | medium | 34/50 | 24 | 10 | 29.78 | 3.2 |
| 34 | cc-haiku55 (global.anthropic.claude-haiku-5-5) | low | 33/50 | 22 | 11 | 0.68 | 2.9 |
| 35 | kiro-gpt56terra (gpt-5.6-terra) | medium | 33/50 | 22 | 11 | 5.26 | 4.7 |
| 36 | kiro-sonnet5 (claude-sonnet-5) | high | 33/50 | 22 | 11 | 6.70 | 4.9 |
| 37 | cc-sonnet5 (global.anthropic.claude-sonnet-5) | medium | 33/50 | 21 | 12 | 15.98 | 4.4 |
| 38 | codex-gpt6luna (global.openai.gpt-6-luna) | high | 32/50 | 18 | 14 | 0.55 | 7.7 |
| 39 | codex-gpt6luna (global.openai.gpt-6-luna) | medium | 30/50 | 19 | 11 | 0.58 | 6.5 |
| 40 | codex-gpt56terra (global.openai.gpt-5.6-terra) | medium | 30/50 | 22 | 8 | 7.84 | 1.5 |
| 41 | codex-gpt56sol (global.openai.gpt-5.6-sol) | low | 29/50 | 20 | 9 | 12.86 | 1.4 |
| 42 | kiro-gpt56terra (gpt-5.6-terra) | low | 28/50 | 22 | 6 | 4.08 | 4.3 |
| 43 | codex-gpt6luna (global.openai.gpt-6-luna) | low | 23/50 | 20 | 3 | 0.25 | 2.4 |
| 44 | kiro-sonnet5 (claude-sonnet-5) | low | 23/50 | 16 | 7 | 3.53 | 5.5 |
| 45 | codex-gpt56terra (global.openai.gpt-5.6-terra) | low | 23/50 | 17 | 6 | 6.78 | 1.4 |

## 运行中遇到的问题

- **kiro-cli 限流：** 并发太高时 Kiro 后端返回 `The request was throttled by the service`。231 个 trial 因此失败，已用 `scripts/throttles.py` 找出，用 `scripts/retry_throttled.py` 以每个 run 1 并发重跑并合并。opus-5 / sonnet-5 受影响最大，例如 kiro + opus-5 medium 从 12 → 34。表中是合并后的结果。
- **trial 丢失：** 少数 batch 进程中途退出，缺的任务用同样的配置补跑后合并。
- **安全拒答：** Opus 5.5 拒答了 Hard20 里的 6 个任务（破解、绕过 XSS 过滤、DNA/蛋白质设计），Opus 5 拒答了 `crack-7z-hash` 和 `break-filter-js-from-html`，都算作失败。用 `scripts/refusals.py` 可以查看。
