# Parameter Guide

Use this when a user asks how to use the skill or wants help choosing runtime parameters. Keep the conversation guided: explain choices, recommend defaults, ask only for missing values, then configure and run.

## Simple Explanation

This skill creates a reusable project package. Runtime settings live in the generated package:

```text
EDIT-TASK-PARAMS.ps1
configs/paper-reading-pool-config.json
```

Prefer `scripts/set-zotero-collection.ps1` for collection paths and `EDIT-TASK-PARAMS.ps1` for runtime parameters.

## Ask For These Choices

```text
Where should I create the project package?
Which Zotero collection path or key should be processed?
Which model should run the notes?
How many workers should run after the first test succeeds?
Do you prefer quality or speed?
Should web search be enabled?
How often should the monitor refresh?
Should I configure only, run one test, run one-shot workers, or start the persistent pool?
```

## Recommended Defaults

```text
Model: mimo-v2.5
ReasoningEffort: xhigh
WireApi: auto
EnableSearch: true, but direct chat mode disables effective Responses search
WorkerCount: 1 for the first test, then 5-10; use 25 only after stable runs
WorkerSleepSeconds: 30
MonitorRefreshSeconds: 60
MaxAttempts: 3
LeaseHours: 3
MaxRunningPerCollection: 1 for stability; one-shot worker script can pass a temporary override without rewriting config
Sandbox: workspace-write
AskForApproval: never
```

## First Run Sequence

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\health-check.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\set-zotero-collection.ps1" -Path "Top Collection -> Child Collection" -RebuildQueue
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -Once
```

If the one-worker foreground run succeeds, process a finite batch with one-shot workers:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-once-workers.ps1" -WorkerCount 3
```

Use the persistent pool only for long unattended runs.


## New reliability and quality settings

Add a stable `projectId` and `runtimeNamespace` for every package. Keep `maxRunningPerCollection = 1` until a foreground test succeeds. Shared fallbacks are in `configs/paper-reading-pool-defaults.json`.

The queue now separates missing or unusable PDF states. After rebuilding the queue, inspect `queue/excluded-pdf-report.md` and `queue/excluded-pdf-report.csv`. Do not treat `pdf_attachment` as readable until the state is `pdf_ready`.

For quality-sensitive runs, keep `pdfChunkingEnabled = true`, `pdfMaxCharsPerChunk = 18000`, `pdfChunkOverlapChars = 1200`, and `pdfMaxPagesPerChunk = 4`. The model must return page/section/chunk evidence in the structured JSON block. The worker validates the sidecar before finalizing the queue item.

Machine-readable outputs are idempotent: `study-data/papers.jsonl` has one record per `collectionKey + itemKey`, and `study-data/evidence.jsonl` has one record per evidence id.
