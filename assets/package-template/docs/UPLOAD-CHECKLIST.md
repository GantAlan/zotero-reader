# Upload Checklist

Use this checklist before uploading the workflow to a project repository.

## Include

```text
README.md
docs/
scripts/
  set-zotero-collection.ps1
  run-once-workers.ps1
configs/paper-reading-pool-config.example.json
configs/paper-reading-pool-config.json
EDIT-TASK-PARAMS.ps1
EDIT-TASK-PARAMS.annotated.ps1
study-paper-template/
.gitignore
```

If the repository is public, prefer committing only the example config and keep the local config private.

## Usually Exclude

```text
logs/
logs-*/
queue/*
study-paper/
study-paper-smoke*/
study-paper-worker-once-test*/
```

These files can contain runtime logs, extracted full text, prompts, queue state, model outputs, and local Zotero item metadata.

## Secret Check

Run:

```powershell
rg -n -i "api[_-]?key|secret|token|password|authorization|bearer" .
```

Expected result for the clean workflow package: no real secret values. References to environment variable names such as `OPENAI_API_KEY` are okay.

## Local Path Check

Run:

```powershell
rg -n "C:\\Users|D:\\|E:\\|F:\\" .
```

Review any matches. Some example paths are harmless, but public repositories should avoid machine-specific paths unless they are documented examples.

## Functional Check

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\health-check.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-zotero-paper-reading-pool.ps1" -QueueStatus
```

If Zotero notes have been imported, also run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\verify-zotero-note-imports.ps1"
```

## Git Commands

From the package root:

```powershell
git status
git add README.md docs scripts configs EDIT-TASK-PARAMS.ps1 EDIT-TASK-PARAMS.annotated.ps1 study-paper-template .gitignore queue/.gitkeep
git status
```

Commit only after reviewing the staged file list.

