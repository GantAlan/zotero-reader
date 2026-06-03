param(
  [string]$PackageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$ZoteroApiBase = 'http://127.0.0.1:23119/api/users/0',
  [string]$ReportName = 'zotero-note-import-full-verify',
  [switch]$FailOnIssues
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$QueueDir = Join-Path $PackageRoot 'queue'
$QueuePath = Join-Path $QueueDir 'paper-reading-pool-queue.json'
$StatePath = Join-Path $QueueDir 'zotero-note-import-state.json'
$ReportPath = Join-Path $QueueDir "$ReportName.json"
$CsvPath = Join-Path $QueueDir "$ReportName.csv"

if (-not (Test-Path -LiteralPath $QueuePath)) {
  throw "Queue file not found: $QueuePath"
}
if (-not (Test-Path -LiteralPath $StatePath)) {
  throw "Import state file not found: $StatePath"
}

function Invoke-Python {
  param([Parameter(Mandatory = $true)][string]$Code)
  $env:PYTHONIOENCODING = 'utf-8'
  $output = $Code | python -
  if ($LASTEXITCODE -ne 0) {
    throw "Python verifier failed with exit code $LASTEXITCODE"
  }
  return $output
}

$verifyCode = @'
import csv
import datetime as dt
import hashlib
import html
import json
import pathlib
import time
import urllib.error
import urllib.request

root = pathlib.Path(r"__PACKAGE_ROOT__")
queue_path = pathlib.Path(r"__QUEUE_PATH__")
state_path = pathlib.Path(r"__STATE_PATH__")
report_path = pathlib.Path(r"__REPORT_PATH__")
csv_path = pathlib.Path(r"__CSV_PATH__")
api_base = "__ZOTERO_API_BASE__".rstrip("/")

queue = json.loads(queue_path.read_text(encoding="utf-8-sig"))
items = queue.get("items", queue if isinstance(queue, list) else [])
state = json.loads(state_path.read_text(encoding="utf-8-sig"))
entries = state.get("entries", [])
by_hash = {e.get("sourceHash"): e for e in entries if e.get("sourceHash")}

def fetch_item(key):
    url = f"{api_base}/items/{key}?include=data"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)

rows = []
issue_counts = {}
started = dt.datetime.now()
eligible = [
    rec for rec in items
    if rec.get("status") == "done" and rec.get("itemKey") and rec.get("outputFile")
]

for i, rec in enumerate(sorted(eligible, key=lambda r: int(r.get("globalIndex") or 999999)), 1):
    issues = []
    source_path = pathlib.Path(rec["outputFile"])
    if not source_path.is_absolute():
        source_path = root / source_path

    source_exists = source_path.exists()
    source_hash = None
    if source_exists:
        source_hash = hashlib.sha256(source_path.read_bytes()).hexdigest().lower()
    else:
        issues.append("source_file_missing")

    entry = by_hash.get(source_hash) if source_hash else None
    if not entry:
        issues.append("state_entry_missing")
        row = {
            "globalIndex": rec.get("globalIndex"),
            "itemKey": rec.get("itemKey"),
            "title": rec.get("title"),
            "sourcePath": str(source_path),
            "sourceHash": source_hash,
            "importStatus": None,
            "noteKey": None,
            "apiFound": False,
            "apiError": None,
            "itemType": None,
            "parentItem": None,
            "parentOk": False,
            "containsHash": False,
            "containsPath": False,
            "containsFileName": False,
            "htmlChars": 0,
            "ok": False,
            "issues": issues,
        }
        rows.append(row)
        for issue in issues:
            issue_counts[issue] = issue_counts.get(issue, 0) + 1
        continue

    note_key = entry.get("noteKey")
    if not note_key:
        issues.append("note_key_missing")

    api_found = False
    api_error = None
    item_type = None
    parent_item = None
    html_text = ""

    if note_key:
        try:
            item = fetch_item(note_key)
            api_found = True
            data = item.get("data", {})
            item_type = data.get("itemType")
            parent_item = data.get("parentItem")
            html_text = data.get("note") or ""
        except urllib.error.HTTPError as exc:
            api_error = f"HTTP {exc.code}"
            issues.append("note_api_http_error")
        except Exception as exc:
            api_error = type(exc).__name__ + ": " + str(exc)
            issues.append("note_api_error")

    parent_ok = parent_item == rec.get("itemKey")
    contains_hash = bool(source_hash and source_hash in html_text)
    contains_path = str(source_path) in html_text or html.escape(str(source_path)) in html_text
    contains_file = source_path.name in html_text
    type_ok = item_type == "note"

    if note_key and not api_found:
        issues.append("note_not_found")
    if api_found and not type_ok:
        issues.append("item_type_not_note")
    if api_found and not parent_ok:
        issues.append("parent_mismatch")
    if api_found and not contains_hash:
        issues.append("hash_missing_in_note")
    if api_found and not contains_path:
        issues.append("path_missing_in_note")
    if api_found and len(html_text) < 100:
        issues.append("note_too_short")

    for issue in issues:
        issue_counts[issue] = issue_counts.get(issue, 0) + 1

    rows.append({
        "globalIndex": rec.get("globalIndex"),
        "itemKey": rec.get("itemKey"),
        "title": rec.get("title"),
        "sourcePath": str(source_path),
        "sourceHash": source_hash,
        "importStatus": entry.get("status"),
        "noteKey": note_key,
        "apiFound": api_found,
        "apiError": api_error,
        "itemType": item_type,
        "parentItem": parent_item,
        "parentOk": parent_ok,
        "containsHash": contains_hash,
        "containsPath": contains_path,
        "containsFileName": contains_file,
        "htmlChars": len(html_text),
        "ok": not issues,
        "issues": issues,
    })

    if i % 50 == 0:
        time.sleep(0.1)

finished = dt.datetime.now()
failures = [r for r in rows if not r["ok"]]
status_counts = {}
for row in rows:
    status = row.get("importStatus")
    status_counts[status] = status_counts.get(status, 0) + 1

report = {
    "ok": len(failures) == 0,
    "startedAt": started.strftime("%Y-%m-%d %H:%M:%S"),
    "finishedAt": finished.strftime("%Y-%m-%d %H:%M:%S"),
    "seconds": round((finished - started).total_seconds(), 3),
    "packageRoot": str(root),
    "queuePath": str(queue_path),
    "statePath": str(state_path),
    "totalQueueItems": len(items),
    "eligibleDoneResults": len(eligible),
    "checked": len(rows),
    "passed": len(rows) - len(failures),
    "failed": len(failures),
    "statusCounts": status_counts,
    "issueCounts": issue_counts,
    "failureGlobalIndexes": [r.get("globalIndex") for r in failures],
    "failures": failures,
    "rows": rows,
}
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

fieldnames = [
    "globalIndex", "ok", "issues", "importStatus", "itemKey", "noteKey",
    "parentItem", "parentOk", "apiFound", "itemType", "containsHash",
    "containsPath", "containsFileName", "htmlChars", "title", "sourcePath",
    "sourceHash", "apiError"
]
with csv_path.open("w", encoding="utf-8-sig", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    for row in rows:
        out = {k: row.get(k) for k in fieldnames}
        out["issues"] = ";".join(row.get("issues") or [])
        writer.writerow(out)

print(json.dumps({
    "ok": report["ok"],
    "checked": report["checked"],
    "passed": report["passed"],
    "failed": report["failed"],
    "statusCounts": report["statusCounts"],
    "issueCounts": report["issueCounts"],
    "failureGlobalIndexes": report["failureGlobalIndexes"],
    "reportPath": str(report_path),
    "csvPath": str(csv_path),
    "seconds": report["seconds"],
}, ensure_ascii=False, indent=2))
'@

$verifyCode = $verifyCode.
  Replace('__PACKAGE_ROOT__', $PackageRoot.Replace('\', '\\')).
  Replace('__QUEUE_PATH__', $QueuePath.Replace('\', '\\')).
  Replace('__STATE_PATH__', $StatePath.Replace('\', '\\')).
  Replace('__REPORT_PATH__', $ReportPath.Replace('\', '\\')).
  Replace('__CSV_PATH__', $CsvPath.Replace('\', '\\')).
  Replace('__ZOTERO_API_BASE__', $ZoteroApiBase)

$output = Invoke-Python -Code $verifyCode
Write-Output $output

if ($FailOnIssues) {
  $summary = $output | ConvertFrom-Json
  if (-not $summary.ok) {
    exit 2
  }
}

