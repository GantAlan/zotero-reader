# zotero-reader

A Codex Skill for Zotero-oriented paper reading workflows, including a bundled paper-reading pool package template.

## Install

Copy this folder into your Codex skills directory:

```powershell
Copy-Item -Recurse .\zotero-reader "$env:USERPROFILE\.codex\skills\zotero-reader"
```

Then ask Codex to use the `zotero-reader` skill.

## Safety

Do not commit real API keys, `.env` files, local logs, or generated runtime state.
