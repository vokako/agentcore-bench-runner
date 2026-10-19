# TB2-Fast30

TB2-Fast30 是从 Terminal-Bench 2.0 里挑出的 30 个任务，用来快速比较不同 agent harness 的效果、耗时和花费。任务清单在 `benchmarks/tb2-fast30.txt`，任务文件本身没有改动。

## 筛选规则

1. **超时短**：`task.toml` 里 `[agent].timeout_sec` ≤ 1200 s（28 个是 900 s 及以下，2 个是 1200 s）；判分时间实测都在 45 s 以内。
2. **microVM 两轮都没有环境问题**：排除了镜像超限、解压后过大、磁盘写满、端口 8080 冲突、lost 和构建失败的任务。
3. **实测耗时短**：两轮里 agent 实际用时都低于超时，没有一次是跑满超时被杀的。
4. **类型多样**：覆盖 TB2 的 13 个类别，难度和通过情况都有分布。
5. **资源**：全部 cpus ≤ 2、内存 ≤ 8 GB，microVM 默认配额就能跑。

## 构成

| 类别 | 任务 |
|---|---|
| software-engineering (6) | fix-git, cobol-modernization, kv-store-grpc, build-pmars, headless-terminal, torch-pipeline-parallelism |
| security (4) | fix-code-vulnerability, openssl-selfsigned-cert, password-recovery, sanitize-git-repo |
| data-processing (3) | log-summary-date-ranges, regex-log, financial-document-processor |
| file-operations (3) | extract-elf, db-wal-recovery, large-scale-text-editing |
| debugging (3) | overfull-hbox, merge-diff-arc-agi-task, sqlite-db-truncate |
| scientific-computing (3) | modernize-scientific-stack, adaptive-rejection-sampler, raman-fitting |
| mathematics (2) | largest-eigenval, model-extraction-relu-logits |
| data-science / model-training / games / personal-assistant / data-querying / system-administration (各 1) | hf-model-inference, count-dataset-tokens, chess-best-move, constraints-scheduling, sparql-university, sqlite-with-gcov |

- 难度（任务自标）：easy 3，medium 22，hard 5。
- Claude Code 在 microVM 上的历史结果：第一轮 26/30，第二轮 23/30。有 10 个任务两轮结果不同或一直失败，它们最能区分 harness；其余 20 个主要用来比较耗时和花费。

## 预计耗时

- 每个 trial 实测约 1-13 分钟（冷启动约 12 s + 安装约 15 s + agent + 判分），最长约 13 分钟。
- 30 个任务，10 个并发：一轮约 15-20 分钟。最坏情况每个任务都跑满超时，一轮约 1.5 小时。
- 建议每个 harness 跑 3 轮：一个 harness 约 1 小时，3 个 harness 约 3 小时。

以上是按 Claude Code 的历史耗时推算的，换 harness 后耗时会变，没有按子集实测过。

## 已知局限

- 30 个任务里一个任务占 3.3 个百分点，单轮分数波动大，要看多轮平均值和范围。
- 偏向较容易的任务（历史通过率约 80%），对最强的 harness 区分度有限。需要更难的对比时，加入超时 1800 s 以上的任务。
- 没有纳入需要网络服务的 system-administration 任务（它们在 microVM 上碰到 8080 冲突），所以该类别只有 1 个。

## 运行

```bash
python3 runner/batch.py --mode microvm --image '<registry>/bench/{task}:arm64' \
  --jobs 10 --out runs/fast30-<harness>-r1 \
  $(grep -v '^#' benchmarks/tb2-fast30.txt | sed 's|^|<tb2-dir>/|')
```
