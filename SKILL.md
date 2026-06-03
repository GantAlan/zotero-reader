---
name: zotero-reader
description: Set up, run, monitor, tune, package, share, and verify a Windows Zotero/Codex paper-reading worker pool. Use when the user asks how to use this skill, wants guided first-run setup, needs help choosing model/worker/reasoning/wire API/search/monitor parameters, asks to create a reusable Zotero paper-reading automation package, generate queues from Zotero collection paths or keys, run one-shot or persistent worker pools, troubleshoot failed workers, import generated Markdown reading notes back into Zotero child notes, or validate note imports.
---

# Zotero Reader

Use this skill for the Windows Zotero/Codex automation workflow that turns Zotero collection items into a queue, runs Codex workers to produce Markdown reading notes, and imports those notes back into Zotero as child notes.

## Quick Decisions

- For a new reusable project, copy `assets/package-template/` or run `scripts/scaffold-package.ps1`.
- For a Zotero collection path such as `Top Collection -> Child Collection`, use the package script `scripts/set-zotero-collection.ps1`; do not hand-edit collection keys unless needed.
- For exact commands, package layout, one-shot workers, and troubleshooting details, read `references/workflow.md`.
- For user-facing installation and usage instructions, read `references/README.zh-CN.md` for Chinese or `references/README.en.md` for English.
- For an existing project, inspect `configs/paper-reading-pool-config.json`, `EDIT-TASK-PARAMS.ps1`, `queue/`, `logs/`, and `study-paper/` before changing behavior.
- For Zotero note import or verification, prefer the bundled package scripts; do not write directly to Zotero SQLite.

## Guided First Use

Explain that the skill creates and operates a separate project package. Collect only the missing choices:

```text
Destination path
Zotero collection path or key
Model
WorkerCount
ReasoningEffort
WireApi
EnableSearch
MonitorRefreshSeconds
Start mode
```

Use safe defaults unless the user chooses otherwise:

```text
Model = mimo-v2.5
WorkerCount = 1 for the first foreground test, then 5-10, then 25 only after stable runs
ReasoningEffort = xhigh for quality, medium for speed
WireApi = auto
EnableSearch = true, but direct chat mode logs effective search as disabled
MonitorRefreshSeconds = 60
MaxRunningPerCollection = 1 for first test; raise only when intentionally parallelizing one collection
Start mode = health check, set collection, queue build, one-worker test, then one-shot workers or pool start
```

## Scaffold A Package

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-root>\scripts\scaffold-package.ps1" -Destination "C:\path\to\zotero-paper-reading-pool"
```

Ask before overwriting or merging into a non-empty directory. Use `-Force` only when the user explicitly wants to merge the template into that destination.

## Configure A Zotero Collection

In the package root, prefer collection path selection:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\set-zotero-collection.ps1" -Path "Top Collection -> Child Collection" -RebuildQueue
```

This resolves the collection key, writes `configs/paper-reading-pool-config.json`, rebuilds the queue, and reports PDF-backed items versus no-PDF exclusions.

## Operating Flow

Start with deterministic checks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\health-check.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -QueueStatus
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -Once
```

Only raise concurrency after a one-worker foreground run succeeds. For a finite batch such as "use 3 workers to run the remaining 3", prefer one-shot workers:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-once-workers.ps1" -WorkerCount 3
```

Use persistent background workers only for longer unattended runs:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\start-paper-reading-pool.ps1"
```

## Quality And Queue Rules

- Queue status must report both queue progress and actual PDF/no-PDF counts.
- `queue/excluded-no-pdf-report.md` and `.csv` identify Zotero items that cannot be read until a PDF is added.
- Generated notes are written by the worker script after parsing model output; the model must not write files.
- The worker injects and enforces the current generated timestamp for the Basic Information Date row.
- Keep separate note copies for the same paper in different Zotero collection paths.

## Zotero Note Import

Use serialized imports:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\import-zotero-notes-batch10.ps1" -BatchSize 10 -RunTimeoutSeconds 240
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\import-zotero-notes-all.ps1" -BatchSize 10 -RunTimeoutSeconds 240
```

Do not run multiple Zotero note writers concurrently. Verify imported notes with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\verify-zotero-note-imports.ps1"
```
