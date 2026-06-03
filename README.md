# zotero-reader

A Codex Skill for Zotero-oriented paper reading workflows, including a bundled paper-reading pool package template.

中文说明 / Chinese guide: [README-cn.md](README-cn.md)

## What it does

`zotero-reader` helps you create and run a Windows Zotero/Codex paper-reading worker pool:

- Build a reading queue from Zotero collections.
- Run Codex workers to generate Markdown reading notes.
- Monitor queue and worker status.
- Import generated notes back into Zotero as child notes.
- Package a reusable paper-reading automation project.

## Installation

### Option A: clone from GitHub

```powershell
cd $env:USERPROFILE\.codex\skills
git clone https://github.com/GantAlan/zotero-reader.git zotero-reader
```

The final path should be:

```text
%USERPROFILE%\.codex\skills\zotero-reader\SKILL.md
```

### Option B: download ZIP

1. Open <https://github.com/GantAlan/zotero-reader>.
2. Click `Code -> Download ZIP`.
3. Extract it.
4. Copy the `zotero-reader` folder into `%USERPROFILE%\.codex\skills\`.

### Option C: copy an existing folder

```powershell
Copy-Item -Recurse .\zotero-reader "$env:USERPROFILE\.codex\skills\zotero-reader"
```

Then ask Codex to use the `zotero-reader` skill.

## First run

Ask Codex:

```text
Use zotero-reader to create a Zotero paper-reading pool project.
```

Or scaffold a reusable package manually:

```powershell
cd "$env:USERPROFILE\.codex\skills\zotero-reader"
.\scripts\scaffold-package.ps1 -Destination "C:\Users\<your-user-name>\Desktop\paper-reading-pool"
```

Then enter the generated package and follow its docs:

```powershell
cd "C:\Users\<your-user-name>\Desktop\paper-reading-pool"
```

## Typical workflow

1. Open Zotero Desktop.
2. Scaffold a package.
3. Configure the target Zotero collection.
4. Generate or inspect the queue.
5. Run one-shot workers or persistent workers.
6. Review generated Markdown notes.
7. Import notes back into Zotero.

Useful package scripts:

```powershell
.\scripts\set-zotero-collection.ps1
.\scripts\run-once-workers.ps1
.\scripts\start-paper-reading-pool.ps1
.\scripts\manage-paper-reading-pool.ps1
.\scripts\import-zotero-notes-all.ps1
.\scripts\verify-zotero-note-imports.ps1
```

## Safety

Do not commit real API keys, `.env` files, local logs, generated runtime state, or private reading notes unless you intentionally want them public.

## More docs

- `references/README.en.md`
- `references/README.zh-CN.md`
- `references/workflow.md`
- `references/parameter-guide.md`
- `assets/package-template/docs/`
