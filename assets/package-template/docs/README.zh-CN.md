# Zotero Reader 中文使用说明

`zotero-reader` 是一个 Windows Codex 技能，用来把 Zotero 分组里的论文变成可并行处理的阅读队列，调用 Codex worker 逐篇阅读 PDF，并生成 Markdown 阅读笔记。它也提供可选脚本，把生成的 Markdown 笔记导入回 Zotero 子笔记。

## 快速开始

打开 Zotero Desktop，然后在运行包目录中执行：

```powershell
$env:NO_PROXY='localhost,127.0.0.1'
$env:no_proxy='localhost,127.0.0.1'

# 如果 Zotero 本地 API 使用了非默认地址或端口，请在配置中设置 zoteroLocalApiBaseUrl。
# 例如：zoteroLocalApiBaseUrl = http://127.0.0.1:23120
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\set-zotero-collection.ps1" -Path "一级分组 -> 二级分组" -RebuildQueue
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -QueueStatus
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -Once
```

单 worker 成功后，再启动多个一次性 worker：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-once-workers.ps1" -WorkerCount 3
```

## 说明

本文件是运行包内的完整中文快速说明。技能仓库中的 `references/README.zh-CN.md` 提供维护者使用的扩展说明；运行包本身不需要复制 `references/` 目录。

常用文件：

```text
EDIT-TASK-PARAMS.ps1
configs/paper-reading-pool-config.json
queue/paper-reading-pool-queue.json
state/current-run.json
study-data/papers.jsonl
study-data/evidence.jsonl
queue/excluded-no-pdf-report.md
study-paper/
```

推荐默认值：

```text
Model = mimo-v2.5
WorkerCount = 1
ReasoningEffort = xhigh
WireApi = auto
EnableSearch = true
MonitorRefreshSeconds = 60
AskForApproval = never
Sandbox = workspace-write
MaxRunningPerCollection = 1
```

不要一开始开很多 worker。先跑一篇，确认模型、Zotero、PDF 和输出路径都正常，再提高并发。


## 运行可靠性与隐私

- `QueueOnly` 会检查 PDF 附件是否真的能解析到本机文件，并分类为 `no_attachment`、`attachment_not_local`、`file_missing`、`unsupported_file`、`pdf_ready`。模型调用阶段的文本提取失败会记录为 `pdf_extract_failed`。
- 每次运行写入 `state/current-run.json`、`state/runs/<runId>/run.json` 和 worker PID 状态文件。停止进程前会核对 PID、启动时间、脚本路径、配置路径、workerId 和 runId。
- `projectId` 留空时会根据包目录自动生成稳定标识；如果需要跨目录迁移后保持同一身份，请手动设置唯一的 `projectId`。项目 mutex 和计划任务名会自动带上项目标识。
- 统一默认值位于 `configs/paper-reading-pool-defaults.json`。成功任务默认不长期保留 prompt、PDF 分块全文和原始模型输出；`logRetentionDays` 控制日志清理。

## 分块阅读与结构化数据

- worker 使用 `extract-pdf-chunks.py` 生成带页码、章节和 chunkId 的 PDF 分块。
- 每篇笔记同时生成 Markdown 和结构化 JSON sidecar；`validate-reading-note.py` 会校验 chunk/evidence 页码锚点。
- 研究数据会幂等写入 `study-data/papers.jsonl` 与 `study-data/evidence.jsonl`，可直接用于后续分析。

手动验证结构化笔记：

```powershell
python .\scripts\validate-reading-note.py .\study-paper\<collection>\<note>.json
```

如果健康检查提示缺少 PDF 提取后端，请在运行包使用的 Python 环境中安装：

```powershell
python -m pip install pypdf
```
