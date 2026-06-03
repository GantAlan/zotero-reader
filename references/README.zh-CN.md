# Zotero Reader 中文使用说明

`zotero-reader` 是一个 Windows Codex 技能，用来把 Zotero 分组里的论文变成可并行处理的阅读队列，调用 Codex worker 逐篇阅读 PDF，并生成 Markdown 阅读笔记。它也提供可选脚本，把生成的 Markdown 笔记导入回 Zotero 子笔记。

## 1. 运行机制

这个技能分成两层：

1. **技能本体**：安装在 `C:\Users\<你的用户名>\.codex\skills\zotero-reader`，供 Codex 识别、读取说明和复制模板。
2. **运行包**：由技能复制出来的独立项目目录。真正的配置、队列、日志、阅读笔记都在运行包里生成。

推荐做法是：不要直接在技能目录里跑论文阅读；先创建运行包，再进入运行包操作。

## 2. 安装技能

把整个 `zotero-reader` 文件夹复制到：

```powershell
C:\Users\<你的用户名>\.codex\skills\zotero-reader
```

目录结构应类似：

```text
zotero-reader/
  SKILL.md
  agents/
  scripts/
    scaffold-package.ps1
  references/
  assets/
    package-template/
```

## 3. 使用前准备

需要：

- Windows PowerShell。
- Zotero Desktop 已打开。
- Zotero 本地 API 可访问：`http://127.0.0.1:23119`。
- Codex CLI 或 Codex Desktop 可用。
- 目标 Zotero 分组中的文献最好带 PDF 附件；没有 PDF 的文献会被写入排除报告。

建议在 PowerShell 中设置：

```powershell
$env:NO_PROXY='localhost,127.0.0.1'
$env:no_proxy='localhost,127.0.0.1'
```

## 4. 创建运行包

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\<你的用户名>\.codex\skills\zotero-reader\scripts\scaffold-package.ps1" -Destination "C:\Users\<你的用户名>\Desktop\zotero-paper-reading-pool"
```

进入运行包：

```powershell
cd "C:\Users\<你的用户名>\Desktop\zotero-paper-reading-pool"
```

如果目标目录已经有内容，并且你明确要合并模板，再加 `-Force`。

## 5. 配置运行参数

优先编辑：

```powershell
.\EDIT-TASK-PARAMS.ps1
```

推荐起步值：

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

编辑后应用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\EDIT-TASK-PARAMS.ps1"
```

建议先用 1 个 worker 测试；稳定后再用 5-10 个。不要一开始开 25 个 worker。

## 6. 选择 Zotero 分组并生成队列

用 Zotero 分组路径：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\set-zotero-collection.ps1" -Path "一级分组 -> 二级分组" -RebuildQueue
```

也可以用 collection key：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\set-zotero-collection.ps1" -Key "HDCE44ZB" -RebuildQueue
```

生成的关键文件：

```text
configs/paper-reading-pool-config.json
queue/paper-reading-pool-queue.json
queue/excluded-no-pdf-report.md
queue/excluded-no-pdf-report.csv
```

## 7. 查看队列状态

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -QueueStatus
```

重要字段：

- `totalZoteroItems`：Zotero 分组里的书目文献总数。
- `pdfBackedItems` / `total`：有 PDF、进入阅读队列的数量。
- `excludedNoPdfCount`：没有 PDF、被排除的数量。
- `statusCounts.pending`：等待阅读的数量。
- `statusCounts.done`：已完成数量。
- `statusCounts.failed`：失败数量。

## 8. 先跑一个 worker 测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -Once
```

成功后，Markdown 阅读笔记会生成到：

```text
study-paper/<一级分组>/<二级分组>/
```

## 9. 多 worker 一次性处理剩余任务

例如用 3 个 worker：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-once-workers.ps1" -WorkerCount 3
```

这个脚本适合处理有限批次。它会启动多个后台 job，等待它们结束，并在运行期间显示队列状态。默认情况下，它会临时提高 `MaxRunningPerCollection` 以允许同一分组并行，结束后恢复原值。

## 10. 长时间无人值守运行

如果任务很多，可以启动持久 worker 池：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\start-paper-reading-pool.ps1"
```

管理 worker：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\manage-paper-reading-pool.ps1" -Action status
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\manage-paper-reading-pool.ps1" -Action stop
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\manage-paper-reading-pool.ps1" -Action restart
```

## 11. 导入 Markdown 笔记回 Zotero

这是写入 Zotero 的操作。确认你确实要导入后再运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\import-zotero-notes-batch10.ps1" -BatchSize 10 -RunTimeoutSeconds 240
```

导入后验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\verify-zotero-note-imports.ps1"
```

不要并行运行多个 Zotero note import 脚本。

## 12. 常见问题

### Zotero API 连接失败

确认 Zotero Desktop 已打开，并设置 `NO_PROXY=localhost,127.0.0.1`。

### 分组路径找不到

优先确认路径格式是 `一级分组 -> 二级分组`。如果仍失败，使用 collection key。

### Zotero 分组有很多文献，但队列数量少

检查 `queue/excluded-no-pdf-report.md`。没有 PDF 附件的文献不会进入阅读队列。

### 单 worker 失败

先不要提高 `WorkerCount`。优先检查模型、代理、PDF 附件、Codex 命令和日志。

## 13. 上传 GitHub 前注意

如果公开分享，请不要上传运行数据：

```text
logs/
logs-*/
queue/*
study-paper/
study-paper-smoke*/
study-paper-worker-once-test*/
```

可以保留：

```text
queue/.gitkeep
```

上传前检查 secret：

```powershell
rg -n -i "api[_-]?key|secret|token|password|authorization|bearer" .
```

检查本机路径：

```powershell
rg -n "C:\\Users|D:\\|E:\\|F:\\" .
```
