# Zotero Paper Reading Pool Package

This is a Windows package for Zotero/Codex paper-reading automation.

User guides:

- Chinese: `docs/README.zh-CN.md`
- English: `docs/README.en.md`

## First Run

Open PowerShell in this folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\health-check.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\set-zotero-collection.ps1" -Path "Top Collection -> Child Collection" -RebuildQueue
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -Once
```

Replace the collection path with your own Zotero path. Queue status includes total bibliographic items, PDF-backed items, and no-PDF exclusions.

## Run Remaining Items

For finite batches, prefer one-shot workers. They process one item each and exit:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-once-workers.ps1" -WorkerCount 3
```

For long unattended runs, start persistent workers:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\start-paper-reading-pool.ps1"
```

## Tune Task Parameters

Edit the top block in `EDIT-TASK-PARAMS.ps1`, then apply it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\EDIT-TASK-PARAMS.ps1"
```

Safe defaults are `WorkerCount = 1` and `MaxRunningPerCollection = 1`. Raise them only after a one-worker test succeeds.

## Generated Files

Runtime outputs are ignored by default:

```text
queue/
logs/
study-paper/
```

No-PDF reports are generated in `queue/excluded-no-pdf-report.md` and `.csv`.

## Import Notes Back Into Zotero

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\import-zotero-notes-batch10.ps1" -BatchSize 10 -RunTimeoutSeconds 240
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\verify-zotero-note-imports.ps1"
```

Do not run multiple Zotero note writers concurrently.
