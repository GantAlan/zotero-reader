# Zotero Paper Reading Pool Reference

Use this reference for exact commands, package layout, and troubleshooting.

## Package Layout

```text
configs/
docs/
scripts/
  health-check.ps1
  set-zotero-collection.ps1
  run-zotero-paper-reading-pool.ps1
  run-once-workers.ps1
  start-paper-reading-pool.ps1
  manage-paper-reading-pool.ps1
  pool-monitor.ps1
  pool-queue-manager.py
  import-zotero-notes-batch10.ps1
  import-zotero-notes-all.ps1
  verify-zotero-note-imports.ps1
study-paper-template/
queue/.gitkeep
```

## Core Commands

Health check:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\health-check.ps1"
```

Set collection by path and rebuild queue:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\set-zotero-collection.ps1" -Path "Top Collection -> Child Collection" -RebuildQueue
```

Check queue state:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -QueueStatus
```

Queue status reports PDF-backed items, total bibliographic Zotero items, and no-PDF exclusions. No-PDF reports are written to:

```text
queue/excluded-no-pdf-report.md
queue/excluded-no-pdf-report.csv
```

Run one worker in the foreground:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -Once
```

Run N one-shot workers and wait for them to exit:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-once-workers.ps1" -WorkerCount 3
```

Start persistent workers:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\start-paper-reading-pool.ps1"
```

Stop or restart persistent workers:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\manage-paper-reading-pool.ps1" -Action stop
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\manage-paper-reading-pool.ps1" -Action restart
```

## Parameter Panel

Edit `EDIT-TASK-PARAMS.ps1`, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\EDIT-TASK-PARAMS.ps1"
```

Safe initial defaults are `WorkerCount = 1` and `MaxRunningPerCollection = 1`. Raise them only after one-worker success.

## Import Generated Notes Into Zotero

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\import-zotero-notes-batch10.ps1" -BatchSize 10 -RunTimeoutSeconds 240
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\verify-zotero-note-imports.ps1"
```

Keep imports serialized; do not run multiple Zotero note writers concurrently.

## Troubleshooting

- If Zotero API calls fail, set `NO_PROXY=localhost,127.0.0.1` and confirm Zotero Desktop is running.
- If a collection path is not found, use `set-zotero-collection.ps1 -Key <key>` or inspect Zotero collections.
- If total Zotero items are higher than queued items, inspect `queue/excluded-no-pdf-report.md`; missing PDFs are intentionally excluded.
- If a one-worker foreground run fails, do not raise `WorkerCount`; fix model/proxy/Zotero/PDF-text issues first.
- If a non-GPT model is used, keep `WireApi = auto` or `chat`; direct chat mode cannot use Responses-only search tools.


## Reliability and reading-quality runtime

The queue builder probes every bibliographic item before enqueueing it. The availability field is one of: `no_attachment`, `attachment_not_local`, `file_missing`, `unsupported_file`, or `pdf_ready`. Review `queue/excluded-pdf-report.md` after `QueueOnly`. A text extraction error is recorded as `pdf_extract_failed`.

Runtime identity is stored under `state/`:

- `current-run.json` points to the latest project run.
- `runs/<runId>/run.json` stores the run summary.
- `runs/<runId>/workers/<workerId>.json` stores PID, process start time, script/config paths, and status.

Leave `projectId` empty to derive a stable package-directory identity, or set a unique `projectId` before moving/copying the package. The project mutex is derived from the namespace and project id, and scheduled tasks use stable names such as `ZoteroPaperReadingPool_<projectId>_01`.

PDF extraction is page-aware. `extract-pdf-chunks.py` creates chunk ids, page ranges, and section hints. The worker requires a structured JSON block with chunk summaries and evidence anchors before it accepts a Markdown note. The validated sidecar is written next to the note; JSONL records are written to `study-data/papers.jsonl` and `study-data/evidence.jsonl`.

Privacy defaults are conservative: prompts, PDF chunk text, and raw model output are removed after successful tasks. Change `retainPrompts`, `retainPdfText`, `retainRawModelOutput`, `retainFailureDiagnostics`, and `logRetentionDays` only when needed.

Manual evidence rendering:

```powershell
python .\scripts\render-reading-note.py --markdown .\study-paper\<collection>\<note>.md --record .\study-paper\<collection>\<note>.json
```
