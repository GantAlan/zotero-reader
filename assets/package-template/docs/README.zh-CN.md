# Zotero Reader 中文使用说明

`zotero-reader` 是一个 Windows Codex 技能，用来把 Zotero 分组里的论文变成可并行处理的阅读队列，调用 Codex worker 逐篇阅读 PDF，并生成 Markdown 阅读笔记。它也提供可选脚本，把生成的 Markdown 笔记导入回 Zotero 子笔记。

## 快速开始

打开 Zotero Desktop，然后在运行包目录中执行：

```powershell
$env:NO_PROXY='localhost,127.0.0.1'
$env:no_proxy='localhost,127.0.0.1'
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\set-zotero-collection.ps1" -Path "一级分组 -> 二级分组" -RebuildQueue
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -QueueStatus
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -Once
```

单 worker 成功后，再启动多个一次性 worker：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-once-workers.ps1" -WorkerCount 3
```

## 说明

完整中文说明见技能目录中的：

```text
references/README.zh-CN.md
```

常用文件：

```text
EDIT-TASK-PARAMS.ps1
configs/paper-reading-pool-config.json
queue/paper-reading-pool-queue.json
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
