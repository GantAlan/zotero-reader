# Zotero Reader User Guide

`zotero-reader` is a Windows Codex skill for turning papers in a Zotero collection into a parallel reading queue, running Codex workers over PDF-backed items, and producing Markdown reading notes. It also includes optional scripts for importing generated Markdown notes back into Zotero as child notes.

## 1. How It Works

The project has two layers:

1. **Skill folder**: installed under `~/.codex/skills/zotero-reader`; Codex reads this folder to understand the workflow.
2. **Runtime package**: a separate project folder scaffolded from the skill template. Queues, logs, configs, and generated notes are created inside this runtime package.

Do not run paper-reading jobs directly inside the skill folder. Scaffold a runtime package first, then work inside that package.

## 2. Install The Skill

Copy the entire `zotero-reader` folder to your Codex skills directory:

```powershell
C:\Users\<your-user-name>\.codex\skills\zotero-reader
```

Expected layout:

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

## 3. Prerequisites

You need:

- Windows PowerShell.
- Zotero Desktop running.
- Zotero local API available at `http://127.0.0.1:23119`.
- Codex CLI / Codex Desktop available.
- PDF attachments on the Zotero items you want to process. Items without PDFs are excluded and reported.

Recommended PowerShell environment variables:

```powershell
$env:NO_PROXY='localhost,127.0.0.1'
$env:no_proxy='localhost,127.0.0.1'
```

## 4. Scaffold A Runtime Package

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\<your-user-name>\.codex\skills\zotero-reader\scripts\scaffold-package.ps1" -Destination "C:\Users\<your-user-name>\Desktop\zotero-paper-reading-pool"
```

Use `-Force` only when you intentionally want to merge the template into a non-empty destination:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\<your-user-name>\.codex\skills\zotero-reader\scripts\scaffold-package.ps1" -Destination "C:\Users\<your-user-name>\Desktop\zotero-paper-reading-pool" -Force
```

Enter the runtime package:

```powershell
cd "C:\Users\<your-user-name>\Desktop\zotero-paper-reading-pool"
```

## 5. Configure Runtime Parameters

Edit:

```powershell
.\EDIT-TASK-PARAMS.ps1
```

Recommended initial values:

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

Apply the settings:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\EDIT-TASK-PARAMS.ps1"
```

Start with one worker. Increase to 5-10 only after a successful one-worker test. Do not start with 25 workers.

## 6. Select A Zotero Collection And Build The Queue

Use a collection path:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\set-zotero-collection.ps1" -Path "Top Collection -> Child Collection" -RebuildQueue
```

Example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\set-zotero-collection.ps1" -Path "References -> Lab Papers" -RebuildQueue
```

You can also use a collection key:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\set-zotero-collection.ps1" -Key "HDCE44ZB" -RebuildQueue
```

Important generated files:

```text
configs/paper-reading-pool-config.json
queue/paper-reading-pool-queue.json
queue/excluded-no-pdf-report.md
queue/excluded-no-pdf-report.csv
```

## 7. Check Queue Status

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -QueueStatus
```

Important fields:

- `totalZoteroItems`: total bibliographic items in the Zotero collection.
- `pdfBackedItems` / `total`: items with PDFs that entered the reading queue.
- `excludedNoPdfCount`: items excluded because they do not have PDF attachments.
- `statusCounts.pending`: waiting items.
- `statusCounts.done`: completed items.
- `statusCounts.failed`: failed items.

## 8. Run One Foreground Worker First

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -Once
```

Generated Markdown notes are written under:

```text
study-paper/<top-collection>/<child-collection>/
```

## 9. Run Multiple One-Shot Workers

For example, start 3 workers:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-once-workers.ps1" -WorkerCount 3
```

This mode is best for a finite batch. The script starts multiple background jobs, waits for them to finish, and prints queue status while they run. By default, it temporarily raises `MaxRunningPerCollection` to allow same-collection parallelism, then restores the original value.

## 10. Run Persistent Workers

For longer unattended runs:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\start-paper-reading-pool.ps1"
```

Manage workers:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\manage-paper-reading-pool.ps1" -Action status
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\manage-paper-reading-pool.ps1" -Action stop
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\manage-paper-reading-pool.ps1" -Action restart
```

## 11. Import Generated Notes Back Into Zotero

This writes to Zotero. Run it only when you are sure you want to import notes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\import-zotero-notes-batch10.ps1" -BatchSize 10 -RunTimeoutSeconds 240
```

Verify imports:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\verify-zotero-note-imports.ps1"
```

Do not run multiple Zotero note import scripts concurrently.

## 12. Troubleshooting

### Zotero API calls fail

Confirm Zotero Desktop is running and set:

```powershell
$env:NO_PROXY='localhost,127.0.0.1'
$env:no_proxy='localhost,127.0.0.1'
```

### Collection path is not found

Use this path format:

```text
Top Collection -> Child Collection
```

If path matching still fails, use the collection key:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\set-zotero-collection.ps1" -Key "YourCollectionKey" -RebuildQueue
```

### The Zotero collection has many items but the queue is smaller

Open:

```text
queue/excluded-no-pdf-report.md
```

Items without PDF attachments are intentionally excluded from the reading queue.

### One worker fails

Do not increase `WorkerCount` yet. Fix model, proxy, PDF attachment, Codex command, or log issues first.

## 13. Before Publishing To GitHub

For public sharing, do not commit runtime data:

```text
logs/
logs-*/
queue/*
study-paper/
study-paper-smoke*/
study-paper-worker-once-test*/
```

You may keep:

```text
queue/.gitkeep
```

Check for secrets:

```powershell
rg -n -i "api[_-]?key|secret|token|password|authorization|bearer" .
```

Check for machine-specific paths:

```powershell
rg -n "C:\\Users|D:\\|E:\\|F:\\" .
```
