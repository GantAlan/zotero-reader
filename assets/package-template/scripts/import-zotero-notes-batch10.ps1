param(
  [string]$PackageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [int]$BatchSize = 10,
  [string]$ZoteroExe = '',
  [int]$RunTimeoutSeconds = 120,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$QueueDir = Join-Path $PackageRoot 'queue'
$QueuePath = Join-Path $QueueDir 'paper-reading-pool-queue.json'
$StatePath = Join-Path $QueueDir 'zotero-note-import-state.json'
$BatchPayloadPath = Join-Path $QueueDir 'zotero-note-import-next-batch-payload.json'
$BatchCodePath = Join-Path $QueueDir 'zotero-note-import-next-batch-runjs.js'
$BatchResultPath = Join-Path $QueueDir 'zotero-note-import-next-batch-result.json'
$BatchVerifyPath = Join-Path $QueueDir 'zotero-note-import-next-batch-verify.json'

if (-not (Test-Path -LiteralPath $QueuePath)) {
  throw "Queue file not found: $QueuePath"
}

function Resolve-ZoteroExecutable {
  param([string]$ConfiguredPath)

  if ($ConfiguredPath) {
    return [Environment]::ExpandEnvironmentVariables($ConfiguredPath)
  }

  $runningPath = Get-Process -Name zotero -ErrorAction SilentlyContinue |
    Where-Object { $_.Path } |
    Select-Object -ExpandProperty Path -First 1
  $candidates = @(
    $runningPath,
    (Join-Path $env:ProgramFiles 'Zotero\Zotero.exe'),
    $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Zotero\Zotero.exe' }),
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Zotero\Zotero.exe' })
  ) | Where-Object { $_ }

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) { return $candidate }
  }
  return $null
}

$ZoteroExe = Resolve-ZoteroExecutable -ConfiguredPath $ZoteroExe
if (-not $ZoteroExe -or -not (Test-Path -LiteralPath $ZoteroExe)) {
  throw "Zotero executable not found. Start Zotero first or pass -ZoteroExe explicitly."
}

Remove-Item -LiteralPath $BatchResultPath,$BatchVerifyPath -Force -ErrorAction SilentlyContinue

function Invoke-Python {
  param([Parameter(Mandatory=$true)][string]$Code)
  $env:PYTHONIOENCODING = 'utf-8'
  $output = $Code | python -
  if ($LASTEXITCODE -ne 0) {
    throw "Python helper failed with exit code $LASTEXITCODE"
  }
  return $output
}

$prepareCode = @'
import datetime
import hashlib
import json
import pathlib
import sys

try:
    import markdown
except Exception as exc:
    raise SystemExit(f"Python package 'markdown' is required: {exc}")

package_root = pathlib.Path(r"__PACKAGE_ROOT__")
queue_path = pathlib.Path(r"__QUEUE_PATH__")
state_path = pathlib.Path(r"__STATE_PATH__")
payload_path = pathlib.Path(r"__PAYLOAD_PATH__")
code_path = pathlib.Path(r"__CODE_PATH__")
result_path = pathlib.Path(r"__RESULT_PATH__")
batch_size = int("__BATCH_SIZE__")

queue = json.loads(queue_path.read_text(encoding="utf-8-sig"))
items = queue.get("items", queue if isinstance(queue, list) else [])

state = {"version": 1, "updatedAt": None, "packageRoot": str(package_root), "entries": []}
if state_path.exists():
    state = json.loads(state_path.read_text(encoding="utf-8-sig"))

covered_hashes = {
    e.get("sourceHash")
    for e in state.get("entries", [])
    if e.get("status") in ("imported", "skipped_existing") and e.get("sourceHash")
}

def read_text_fallback(path):
    data = path.read_bytes()
    for encoding in ("utf-8-sig", "utf-8", "gb18030", "gbk", "cp1252"):
        try:
            return data.decode(encoding), encoding
        except UnicodeDecodeError:
            pass
    return data.decode("utf-8", errors="replace"), "utf-8-replace"

records = []
for rec in sorted(items, key=lambda x: int(x.get("globalIndex") or 999999)):
    if len(records) >= batch_size:
        break
    if rec.get("status") != "done" or not rec.get("itemKey") or not rec.get("outputFile"):
        continue

    source_path = pathlib.Path(rec["outputFile"])
    if not source_path.is_absolute():
        source_path = package_root / source_path
    if not source_path.exists():
        continue

    source_hash = hashlib.sha256(source_path.read_bytes()).hexdigest().lower()
    if source_hash in covered_hashes:
        continue

    raw, source_encoding = read_text_fallback(source_path)
    collection_path = " / ".join(rec.get("pathParts") or [rec.get("topCollectionName", ""), rec.get("collectionName", "")]).strip(" /")
    header = f"""AI_READING_NOTE_IMPORT
AI_READING_NOTE_IMPORT_SHA256: {source_hash}
Zotero itemKey: {rec.get("itemKey")}
Queue globalIndex: {rec.get("globalIndex")}
Collection path: {collection_path}
Source path: {source_path}
Source encoding: {source_encoding}
Imported at: {datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
Title: {rec.get("title")}

---

"""
    body_html = markdown.markdown(
        header + raw,
        extensions=["extra", "tables", "fenced_code", "sane_lists", "nl2br"],
    )
    note_html = f'<div data-schema-version="9">{body_html}</div>'
    records.append({
        "globalIndex": int(rec.get("globalIndex")),
        "itemKey": rec.get("itemKey"),
        "title": rec.get("title"),
        "sourcePath": str(source_path),
        "sourceFileName": source_path.name,
        "sourceEncoding": source_encoding,
        "sourceHash": source_hash,
        "noteHTML": note_html,
    })

payload = {
    "createdAt": datetime.datetime.now().isoformat(),
    "packageRoot": str(package_root),
    "statePath": str(state_path),
    "resultPath": str(result_path),
    "records": records,
}
payload_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

js = f"""
(async () => {{
  const payloadPath = String.raw`{payload_path}`;
  const resultPath = String.raw`{result_path}`;
  const payload = JSON.parse(await Zotero.File.getContentsAsync(payloadPath));
  const results = [];

  async function getParentItem(itemKey) {{
    const libraryID = Zotero.Libraries.userLibraryID;
    return Zotero.Items.getByLibraryAndKey(libraryID, itemKey)
      || await Zotero.Items.getByLibraryAndKeyAsync(libraryID, itemKey);
  }}

  function findExistingSourceNote(parentItem, rec) {{
    for (const noteID of parentItem.getNotes()) {{
      const note = Zotero.Items.get(noteID);
      if (!note) continue;
      const html = note.getNote() || '';
      if (html.includes(rec.sourceHash) || html.includes(rec.sourcePath) || html.includes(rec.sourceFileName)) {{
        return note;
      }}
    }}
    return null;
  }}

  for (const rec of payload.records) {{
    try {{
      const parent = await getParentItem(rec.itemKey);
      if (!parent) {{
        results.push({{ action: 'failed', error: 'parent_not_found', globalIndex: rec.globalIndex, itemKey: rec.itemKey, title: rec.title, sourcePath: rec.sourcePath, sourceHash: rec.sourceHash }});
        continue;
      }}
      const existing = findExistingSourceNote(parent, rec);
      if (existing) {{
        results.push({{ action: 'skipped_existing', noteKey: existing.key, parentItemKey: parent.key, globalIndex: rec.globalIndex, itemKey: rec.itemKey, title: rec.title, sourcePath: rec.sourcePath, sourceHash: rec.sourceHash }});
        continue;
      }}
      const note = new Zotero.Item('note');
      note.libraryID = parent.libraryID;
      note.parentID = parent.id;
      note.setNote(rec.noteHTML);
      await note.saveTx();
      results.push({{ action: 'imported', noteKey: note.key, parentItemKey: parent.key, globalIndex: rec.globalIndex, itemKey: rec.itemKey, title: rec.title, sourcePath: rec.sourcePath, sourceHash: rec.sourceHash, htmlLength: rec.noteHTML.length }});
    }} catch (e) {{
      results.push({{ action: 'failed', error: String(e && e.stack || e), globalIndex: rec.globalIndex, itemKey: rec.itemKey, title: rec.title, sourcePath: rec.sourcePath, sourceHash: rec.sourceHash }});
    }}
  }}

  const output = {{
    ok: results.every(r => r.action !== 'failed'),
    createdAt: new Date().toISOString(),
    payloadPath,
    resultPath,
    results
  }};
  await Zotero.File.putContentsAsync(resultPath, JSON.stringify(output, null, 2));
  return JSON.stringify({{
    ok: output.ok,
    count: results.length,
    imported: results.filter(r => r.action === 'imported').length,
    skipped: results.filter(r => r.action === 'skipped_existing').length,
    failed: results.filter(r => r.action === 'failed').length
  }});
}})();
""".strip()
code_path.write_text(js, encoding="utf-8")

summary = {
    "batchSize": batch_size,
    "selected": len(records),
    "globalIndexes": [r["globalIndex"] for r in records],
    "payloadPath": str(payload_path),
    "codePath": str(code_path),
    "resultPath": str(result_path),
}
print(json.dumps(summary, ensure_ascii=False, indent=2))
'@

$prepareCode = $prepareCode.
  Replace('__PACKAGE_ROOT__', $PackageRoot.Replace('\', '\\')).
  Replace('__QUEUE_PATH__', $QueuePath.Replace('\', '\\')).
  Replace('__STATE_PATH__', $StatePath.Replace('\', '\\')).
  Replace('__PAYLOAD_PATH__', $BatchPayloadPath.Replace('\', '\\')).
  Replace('__CODE_PATH__', $BatchCodePath.Replace('\', '\\')).
  Replace('__RESULT_PATH__', $BatchResultPath.Replace('\', '\\')).
  Replace('__BATCH_SIZE__', [string]$BatchSize)

$prepareOutput = Invoke-Python -Code $prepareCode
$prepare = $prepareOutput | ConvertFrom-Json

if ($DryRun -or $prepare.selected -eq 0) {
  [ordered]@{
    mode = if ($DryRun) { 'dry_run' } else { 'nothing_to_import' }
    prepared = $prepare
  } | ConvertTo-Json -Depth 8
  exit 0
}

if (Test-Path -LiteralPath $BatchResultPath) {
  Remove-Item -LiteralPath $BatchResultPath -Force
}

Start-Process -FilePath $ZoteroExe -ArgumentList @('-chrome', 'chrome://zotero/content/runJS.html')
Start-Sleep -Seconds 4

$js = Get-Content -LiteralPath $BatchCodePath -Raw -Encoding UTF8
$clipboardSet = $false
for ($i = 0; $i -lt 5 -and -not $clipboardSet; $i++) {
  try {
    Set-Clipboard -Value $js
    $clipboardSet = $true
  }
  catch {
    Start-Sleep -Milliseconds 500
  }
}
if (-not $clipboardSet) {
  throw 'Failed to set clipboard for Zotero RunJS code'
}

$zoteroWindow = Get-Process -Name zotero -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowHandle -ne 0 } |
  Sort-Object @{ Expression = { if ($_.MainWindowTitle -like '*JavaScript*') { 0 } else { 1 } } } |
  Select-Object -First 1
if (-not $zoteroWindow) {
  throw 'No Zotero window found'
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class ImportNoteWin32 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@

$rect = New-Object ImportNoteWin32+RECT
[ImportNoteWin32]::ShowWindow($zoteroWindow.MainWindowHandle, 9) | Out-Null
[ImportNoteWin32]::SetForegroundWindow($zoteroWindow.MainWindowHandle) | Out-Null
[ImportNoteWin32]::GetWindowRect($zoteroWindow.MainWindowHandle, [ref]$rect) | Out-Null

$shell = New-Object -ComObject WScript.Shell
$shell.AppActivate($zoteroWindow.Id) | Out-Null
Start-Sleep -Seconds 1

# Click the code editor first; Zotero's RunJS window is Mozilla-based and
# AppActivate alone can leave keyboard focus in another app.
[ImportNoteWin32]::SetCursorPos($rect.Left + 25, $rect.Top + 120) | Out-Null
[ImportNoteWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 80
[ImportNoteWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 300
$shell.SendKeys('^a')
Start-Sleep -Milliseconds 300
$shell.SendKeys('^v')
Start-Sleep -Milliseconds 800

# Click the Run button instead of relying only on Ctrl+R.
[ImportNoteWin32]::SetCursorPos($rect.Left + 38, $rect.Top + 55) | Out-Null
[ImportNoteWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 80
[ImportNoteWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)

$deadline = (Get-Date).AddSeconds($RunTimeoutSeconds)
while (-not (Test-Path -LiteralPath $BatchResultPath) -and (Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
}
if (-not (Test-Path -LiteralPath $BatchResultPath)) {
  throw "Timed out waiting for Zotero RunJS result: $BatchResultPath"
}

$updateCode = @'
import json
import pathlib
import urllib.request
import datetime
import collections

state_path = pathlib.Path(r"__STATE_PATH__")
result_path = pathlib.Path(r"__RESULT_PATH__")
verify_path = pathlib.Path(r"__VERIFY_PATH__")

state = {"version": 1, "updatedAt": None, "packageRoot": None, "entries": []}
if state_path.exists():
    state = json.loads(state_path.read_text(encoding="utf-8-sig"))
result = json.loads(result_path.read_text(encoding="utf-8-sig"))
by_hash = {e.get("sourceHash"): e for e in state.get("entries", []) if e.get("sourceHash")}
now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

for r in result.get("results", []):
    if r.get("action") in ("imported", "skipped_existing"):
        by_hash[r["sourceHash"]] = {
            "status": r["action"],
            "itemKey": r["itemKey"],
            "noteKey": r.get("noteKey"),
            "globalIndex": r.get("globalIndex"),
            "title": r.get("title"),
            "sourcePath": r.get("sourcePath"),
            "sourceHash": r.get("sourceHash"),
            "htmlLength": r.get("htmlLength"),
            "updatedAt": now,
            "method": "zotero_runjs_internal_api",
        }
    else:
        by_hash[r.get("sourceHash")] = {
            "status": "failed",
            "itemKey": r.get("itemKey"),
            "noteKey": r.get("noteKey"),
            "globalIndex": r.get("globalIndex"),
            "title": r.get("title"),
            "sourcePath": r.get("sourcePath"),
            "sourceHash": r.get("sourceHash"),
            "updatedAt": now,
            "error": r.get("error"),
            "method": "zotero_runjs_internal_api",
        }

state["updatedAt"] = now
state["entries"] = sorted(by_hash.values(), key=lambda e: (e.get("globalIndex") or 999999, e.get("sourcePath") or ""))
state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")

checks = []
for r in result.get("results", []):
    if r.get("action") not in ("imported", "skipped_existing") or not r.get("noteKey"):
        continue
    with urllib.request.urlopen(f"http://127.0.0.1:23119/api/users/0/items/{r['noteKey']}?include=data", timeout=15) as response:
        item = json.load(response)
    html = item.get("data", {}).get("note", "") or ""
    checks.append({
        "globalIndex": r.get("globalIndex"),
        "itemKey": r.get("itemKey"),
        "noteKey": r.get("noteKey"),
        "action": r.get("action"),
        "parentItem": item.get("data", {}).get("parentItem"),
        "htmlChars": len(html),
        "containsHash": r.get("sourceHash") in html if r.get("sourceHash") else None,
        "containsPath": r.get("sourcePath") in html if r.get("sourcePath") else None,
    })

verify = {
    "ok": all(c["action"] != "imported" or (c["containsHash"] and c["containsPath"]) for c in checks),
    "checked": len(checks),
    "failedChecks": [c for c in checks if c["action"] == "imported" and not (c["containsHash"] and c["containsPath"])],
    "resultCounts": dict(collections.Counter(r.get("action") for r in result.get("results", []))),
    "checks": checks,
    "statePath": str(state_path),
    "resultPath": str(result_path),
}
verify_path.write_text(json.dumps(verify, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(verify, ensure_ascii=False, indent=2))
'@

$updateCode = $updateCode.
  Replace('__STATE_PATH__', $StatePath.Replace('\', '\\')).
  Replace('__RESULT_PATH__', $BatchResultPath.Replace('\', '\\')).
  Replace('__VERIFY_PATH__', $BatchVerifyPath.Replace('\', '\\'))

$verifyOutput = Invoke-Python -Code $updateCode

[ordered]@{
  prepared = $prepare
  result = Get-Content -LiteralPath $BatchResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
  verify = $verifyOutput | ConvertFrom-Json
  statePath = $StatePath
  resultPath = $BatchResultPath
  verifyPath = $BatchVerifyPath
} | ConvertTo-Json -Depth 16
