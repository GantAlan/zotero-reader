import csv
import json
import os
import re
import urllib.parse
import urllib.request
from collections import OrderedDict
from datetime import datetime, timedelta
from pathlib import Path

ZOTERO_BASE = os.environ.get("ZOTERO_LOCAL_BASE_URL", "http://127.0.0.1:23119").rstrip("/")
if ZOTERO_BASE.lower().endswith("/api/users/0"):
    ZOTERO_BASE = ZOTERO_BASE[: -len("/api/users/0")].rstrip("/")
BASE = ZOTERO_BASE + "/api/users/0"
HEADERS = {"Zotero-API-Version": "3"}
BIB_TYPES = {"journalArticle", "conferencePaper", "thesis", "bookSection", "book", "preprint", "report"}
PDF_EXTENSIONS = {".pdf"}


def now():
    return datetime.now().strftime("%Y/%m/%d %H:%M:%S")


def parse_time(value):
    if not value:
        return None
    try:
        return datetime.strptime(value, "%Y/%m/%d %H:%M:%S")
    except Exception:
        return None


def fetch(path, params=None):
    body, headers = fetch_text(path, params)
    return json.loads(body) if body else None, headers


def fetch_text(path, params=None):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(url, headers=HEADERS)
    with opener.open(req, timeout=30) as response:
        body = response.read().decode("utf-8", errors="replace")
        return body, dict(response.headers)


def fetch_all(path, params=None):
    params = dict(params or {})
    params.setdefault("limit", 100)
    output = []
    start = 0
    while True:
        params["start"] = start
        chunk, headers = fetch(path, params)
        chunk = chunk or []
        output.extend(chunk)
        total = int(headers.get("Total-Results") or headers.get("Zotero-Total-Results") or len(output))
        if not chunk or len(output) >= total:
            break
        start += len(chunk)
    return output


def load_json(path, fallback):
    path = Path(path)
    if not path.exists():
        return fallback
    return json.loads(path.read_text(encoding="utf-8-sig"))


def save_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def creators(data):
    names = []
    for creator in data.get("creators", []):
        if creator.get("name"):
            names.append(creator["name"])
        else:
            full = " ".join(value for value in [creator.get("firstName"), creator.get("lastName")] if value)
            if full:
                names.append(full)
    return names


def year_from_date(value):
    value = value or ""
    for token in value.replace("/", "-").split("-"):
        if len(token) == 4 and token.isdigit():
            return token
    return value[:4] if len(value) >= 4 and value[:4].isdigit() else None


def local_path_from_file_url(value):
    if not value:
        return None
    raw = str(value).strip().strip('"')
    if raw.startswith("file://"):
        parsed = urllib.parse.urlparse(raw)
        decoded_path = urllib.parse.unquote(parsed.path or "")
        if parsed.netloc and parsed.netloc.lower() not in {"localhost", "127.0.0.1"}:
            return Path("\\\\" + parsed.netloc + decoded_path.replace("/", "\\"))
        if re.match(r"^/[A-Za-z]:", decoded_path):
            decoded_path = decoded_path[1:]
        return Path(decoded_path.replace("/", "\\") if os.name == "nt" else decoded_path)
    decoded = urllib.parse.unquote(raw)
    if re.match(r"^[A-Za-z]:[\\/]", decoded) or decoded.startswith("\\\\"):
        return Path(decoded)
    return None


def parse_file_url_response(raw):
    value = raw.strip() if raw else ""
    if not value:
        return None
    try:
        parsed = json.loads(value)
        if isinstance(parsed, str):
            return parsed
        if isinstance(parsed, dict):
            for key in ("url", "path", "filePath", "fileUrl"):
                if parsed.get(key):
                    return str(parsed[key])
    except Exception:
        pass
    return value


def is_pdf_attachment(data):
    values = [data.get("contentType"), data.get("title"), data.get("filename"), data.get("path")]
    lowered = [(value or "").lower() for value in values]
    return lowered[0] == "application/pdf" or any(value.endswith(".pdf") for value in lowered[1:]) or lowered[1] == "pdf"


def classify_pdf_attachment(item_key):
    children = fetch_all(f"/items/{item_key}/children", {"format": "json"})
    attachments = [child for child in children if child.get("data", {}).get("itemType") == "attachment"]
    if not attachments:
        return None, {"reason": "no_attachment", "detail": "No child attachment was found."}
    pdf_candidates = [child for child in attachments if is_pdf_attachment(child.get("data", {}))]
    if not pdf_candidates:
        return None, {"reason": "unsupported_file", "detail": "Attachments exist, but none is a PDF."}

    issues = []
    for child in pdf_candidates:
        data = child.get("data", {})
        attachment_key = child.get("key")
        attachment_title = data.get("title")
        try:
            raw, _ = fetch_text(f"/items/{attachment_key}/file/view/url")
            file_url = parse_file_url_response(raw)
        except Exception as exc:
            issues.append({"reason": "attachment_not_local", "detail": str(exc), "attachmentKey": attachment_key, "attachmentTitle": attachment_title})
            continue
        local_path = local_path_from_file_url(file_url)
        if not local_path:
            detail = "Zotero did not expose a local file URL."
            if file_url:
                detail = "The attachment URL is not a local file URL."
            issues.append({"reason": "attachment_not_local", "detail": detail, "attachmentKey": attachment_key, "attachmentTitle": attachment_title})
            continue
        suffix = local_path.suffix.lower()
        if suffix not in PDF_EXTENSIONS and (data.get("contentType") or "").lower() != "application/pdf":
            issues.append({
                "reason": "unsupported_file",
                "detail": f"Attachment path has unsupported extension: {suffix or 'none'}.",
                "attachmentKey": attachment_key,
                "attachmentTitle": attachment_title,
            })
            continue
        if not local_path.exists():
            issues.append({
                "reason": "file_missing",
                "detail": "Zotero returned a local path, but the file does not exist.",
                "attachmentKey": attachment_key,
                "attachmentTitle": attachment_title,
            })
            continue
        return {
            "attachmentKey": attachment_key,
            "attachmentTitle": attachment_title,
            "attachmentFilename": data.get("filename"),
            "attachmentContentType": data.get("contentType"),
            "pdfAvailability": "pdf_ready",
        }, None

    priority = {"file_missing": 0, "attachment_not_local": 1, "unsupported_file": 2}
    issue = sorted(issues, key=lambda value: priority.get(value.get("reason"), 99))[0]
    issue["detail"] = "; ".join(sorted({item.get("detail", "") for item in issues if item.get("detail")}))
    return None, issue


def collection_items(collection):
    zotero_items = fetch_all(
        f"/collections/{collection['key']}/items/top",
        {"format": "json", "sort": "dateAdded", "direction": "desc"},
    )
    output = []
    excluded = []
    availability_counts = OrderedDict()
    raw_top_count = len(zotero_items)
    bibliographic_count = 0
    for item in zotero_items:
        data = item.get("data", {})
        item_type = data.get("itemType")
        if item_type not in BIB_TYPES:
            continue
        bibliographic_count += 1
        pdf, issue = classify_pdf_attachment(item.get("key"))
        if issue:
            reason = issue.get("reason", "attachment_not_local")
            availability_counts[reason] = availability_counts.get(reason, 0) + 1
            excluded.append({
                "itemKey": item.get("key"),
                "title": data.get("title"),
                "dateAdded": data.get("dateAdded"),
                "collectionKey": collection["key"],
                "collectionName": collection.get("name"),
                "topCollectionName": collection.get("top"),
                "pathParts": collection.get("pathParts") or [collection.get("top"), collection.get("name")],
                "reason": reason,
                "detail": issue.get("detail"),
                "attachmentKey": issue.get("attachmentKey"),
                "attachmentTitle": issue.get("attachmentTitle"),
            })
            continue
        availability_counts["pdf_ready"] = availability_counts.get("pdf_ready", 0) + 1
        output.append({
            "globalIndex": None,
            "collectionIndex": len(output) + 1,
            "topCollectionName": collection.get("top"),
            "collectionName": collection.get("name"),
            "collectionKey": collection.get("key"),
            "pathParts": collection.get("pathParts") or [collection.get("top"), collection.get("name")],
            "itemKey": item.get("key"),
            "attachmentKey": pdf.get("attachmentKey"),
            "attachmentTitle": pdf.get("attachmentTitle"),
            "attachmentFilename": pdf.get("attachmentFilename"),
            "attachmentContentType": pdf.get("attachmentContentType"),
            "itemType": item_type,
            "title": data.get("title"),
            "publicationTitle": data.get("publicationTitle"),
            "date": data.get("date"),
            "year": year_from_date(data.get("date")),
            "dateAdded": data.get("dateAdded"),
            "DOI": data.get("DOI"),
            "creators": creators(data),
            "pdfAvailability": "pdf_ready",
            "availabilityCheckedAt": now(),
            "status": "pending",
            "attempts": 0,
            "workerId": None,
            "runId": None,
            "outputFile": None,
            "structuredFile": None,
            "startedAt": None,
            "finishedAt": None,
            "lastError": None,
            "failureCode": None,
        })
    return output, excluded, bibliographic_count, raw_top_count, availability_counts


def build_queue(config):
    items = []
    excluded = []
    collection_sources = []
    availability_counts = OrderedDict()
    total_zotero_items = 0
    total_top_items = 0
    for collection in config.get("collections", []):
        collection_queue, collection_excluded, bibliographic_count, raw_top_count, counts = collection_items(collection)
        items.extend(collection_queue)
        excluded.extend(collection_excluded)
        for key, value in counts.items():
            availability_counts[key] = availability_counts.get(key, 0) + value
        total_zotero_items += bibliographic_count
        total_top_items += raw_top_count
        collection_sources.append({
            "topCollectionName": collection.get("top"),
            "collectionName": collection.get("name"),
            "collectionKey": collection.get("key"),
            "pathParts": collection.get("pathParts") or [collection.get("top"), collection.get("name")],
            "totalTopItems": raw_top_count,
            "totalZoteroItems": bibliographic_count,
            "pdfBackedItems": len(collection_queue),
            "excludedPdfCount": len(collection_excluded),
            "excludedNoPdfCount": sum(1 for item in collection_excluded if item.get("reason") == "no_attachment"),
        })
    for index, item in enumerate(items, start=1):
        item["globalIndex"] = index
    no_pdf = [item for item in excluded if item.get("reason") == "no_attachment"]
    return {
        "schemaVersion": 3,
        "queueType": "global-pool",
        "orderBy": "configured_collection_order_then_dateAdded_desc",
        "createdAt": now(),
        "updatedAt": now(),
        "total": len(items),
        "pdfBackedItems": len(items),
        "pdfAttachmentItems": sum(value for key, value in availability_counts.items() if key != "no_attachment"),
        "totalZoteroItems": total_zotero_items,
        "totalTopItems": total_top_items,
        "excludedPdfCount": len(excluded),
        "excludedNoPdfCount": len(no_pdf),
        "pdfAvailabilityCounts": dict(availability_counts),
        "excludedPdf": excluded,
        "excludedNoPdf": no_pdf,
        "collectionSources": collection_sources,
        "items": items,
    }


def merge_progress(new_queue, old_queue):
    if not old_queue:
        return new_queue
    old_by_pair = {(item.get("collectionKey"), item.get("itemKey")): item for item in old_queue.get("items", [])}
    progress_fields = [
        "status", "attempts", "workerId", "runId", "outputFile", "structuredFile", "startedAt", "finishedAt",
        "lastError", "failureCode", "resultFile", "failedAt",
    ]
    for item in new_queue.get("items", []):
        old = old_by_pair.get((item.get("collectionKey"), item.get("itemKey")))
        if not old:
            continue
        for field in progress_fields:
            if field in old:
                item[field] = old[field]
    new_queue["createdAt"] = old_queue.get("createdAt") or new_queue.get("createdAt")
    new_queue["updatedAt"] = now()
    return new_queue


def status_counts(queue):
    counts = {}
    by_collection = OrderedDict()
    failed_by_code = {}
    for item in queue.get("items", []):
        status = item.get("status", "pending")
        counts[status] = counts.get(status, 0) + 1
        if status == "failed":
            code = item.get("failureCode") or "unknown"
            failed_by_code[code] = failed_by_code.get(code, 0) + 1
        key = item.get("collectionKey")
        if key not in by_collection:
            by_collection[key] = {
                "topCollectionName": item.get("topCollectionName"),
                "collectionName": item.get("collectionName"),
                "collectionKey": key,
                "total": 0,
                "pending": 0,
                "running": 0,
                "done": 0,
                "failed": 0,
            }
        by_collection[key]["total"] += 1
        by_collection[key][status] = by_collection[key].get(status, 0) + 1
    return counts, list(by_collection.values()), failed_by_code


def enrich_collection_status(queue, by_collection):
    by_key = OrderedDict((item.get("collectionKey"), dict(item)) for item in by_collection)
    for source in queue.get("collectionSources", []) or []:
        key = source.get("collectionKey")
        current = by_key.get(key)
        if current is None:
            current = {
                "topCollectionName": source.get("topCollectionName"), "collectionName": source.get("collectionName"),
                "collectionKey": key, "total": 0, "pending": 0, "running": 0, "done": 0, "failed": 0,
            }
            by_key[key] = current
        current["totalTopItems"] = source.get("totalTopItems")
        current["totalZoteroItems"] = source.get("totalZoteroItems")
        current["pdfBackedItems"] = source.get("pdfBackedItems", current.get("total", 0))
        current["excludedPdfCount"] = source.get("excludedPdfCount", 0)
        current["excludedNoPdfCount"] = source.get("excludedNoPdfCount", 0)
    return list(by_key.values())


def queue_summary(queue, queue_file=None, include_excluded_preview=True):
    queue = queue or {}
    counts, by_collection, failed_by_code = status_counts(queue)
    by_collection = enrich_collection_status(queue, by_collection)
    total = queue.get("total", len(queue.get("items", [])))
    excluded_count = queue.get("excludedPdfCount", len(queue.get("excludedPdf", queue.get("excludedNoPdf", [])) or []))
    excluded = queue.get("excludedPdf", queue.get("excludedNoPdf", [])) or []
    summary = {
        "queueFile": queue_file,
        "total": total,
        "pdfBackedItems": queue.get("pdfBackedItems", total),
        "pdfAttachmentItems": queue.get("pdfAttachmentItems"),
        "totalZoteroItems": queue.get("totalZoteroItems", (total or 0) + (excluded_count or 0)),
        "totalTopItems": queue.get("totalTopItems"),
        "excludedPdfCount": excluded_count,
        "excludedNoPdfCount": queue.get("excludedNoPdfCount", sum(1 for item in excluded if item.get("reason") == "no_attachment")),
        "pdfAvailabilityCounts": queue.get("pdfAvailabilityCounts", {}),
        "statusCounts": counts,
        "failedByCode": failed_by_code,
        "collections": by_collection,
    }
    if include_excluded_preview:
        summary["excludedPdf"] = excluded[:100]
    return summary


def write_excluded_reports(queue_file, queue):
    excluded = queue.get("excludedPdf", queue.get("excludedNoPdf", [])) or []
    no_pdf = [item for item in excluded if item.get("reason") == "no_attachment"]
    queue_path = Path(queue_file)
    report_md = queue_path.parent / "excluded-pdf-report.md"
    report_csv = queue_path.parent / "excluded-pdf-report.csv"
    lines = ["# Zotero Items Excluded by Local PDF Availability", "", f"Generated: {now()}", f"Count: {len(excluded)}", "", "| itemKey | Collection | Reason | Title |", "|---|---|---|---|"]
    if excluded:
        for item in excluded:
            collection_path = " / ".join(item.get("pathParts") or [item.get("topCollectionName"), item.get("collectionName")])
            title = (item.get("title") or "").replace("|", "\\|")
            lines.append(f"| {item.get('itemKey')} | {collection_path} | {item.get('reason')} | {title} |")
    else:
        lines.append("No items were excluded.")
    report_md.write_text("\n".join(lines) + "\n", encoding="utf-8")
    with report_csv.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["itemKey", "collectionPath", "reason", "detail", "attachmentKey", "dateAdded", "title"])
        writer.writeheader()
        for item in excluded:
            collection_path = " / ".join(item.get("pathParts") or [item.get("topCollectionName"), item.get("collectionName")])
            writer.writerow({"itemKey": item.get("itemKey"), "collectionPath": collection_path, "reason": item.get("reason"), "detail": item.get("detail"), "attachmentKey": item.get("attachmentKey"), "dateAdded": item.get("dateAdded"), "title": item.get("title")})
    old_md = queue_path.parent / "excluded-no-pdf-report.md"
    old_csv = queue_path.parent / "excluded-no-pdf-report.csv"
    no_pdf_lines = ["# Excluded Zotero Items Without a Usable Local PDF", "", f"Generated: {now()}", f"Count: {len(no_pdf)}", "", "| itemKey | Collection | Date Added | Title |", "|---|---|---|---|"]
    for item in no_pdf:
        safe_title = (item.get("title") or "").replace("|", "\\|")
        no_pdf_lines.append(f"| {item.get('itemKey')} | {' / '.join(item.get('pathParts') or [])} | {item.get('dateAdded') or ''} | {safe_title} |")
    old_md.write_text("\n".join(no_pdf_lines) + "\n", encoding="utf-8")
    with old_csv.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["itemKey", "collectionPath", "dateAdded", "title", "reason"])
        writer.writeheader()
        for item in no_pdf:
            writer.writerow({"itemKey": item.get("itemKey"), "collectionPath": " / ".join(item.get("pathParts") or []), "dateAdded": item.get("dateAdded"), "title": item.get("title"), "reason": item.get("reason")})
    return {"excludedPdfReportMd": str(report_md), "excludedPdfReportCsv": str(report_csv), "excludedNoPdfReportMd": str(old_md), "excludedNoPdfReportCsv": str(old_csv)}


def reset_stale(queue):
    lease_hours = int(os.environ.get("LEASE_HOURS", "3"))
    cutoff = datetime.now() - timedelta(hours=lease_hours)
    for item in queue.get("items", []):
        if item.get("status") != "running":
            continue
        started = parse_time(item.get("startedAt"))
        if started and started < cutoff:
            item["status"] = "pending"
            item["lastError"] = "Reset stale running lease."
            item["failureCode"] = "stale_lease"
            item["workerId"] = None
            item["runId"] = None


def running_count(queue, collection_key):
    return sum(1 for item in queue.get("items", []) if item.get("collectionKey") == collection_key and item.get("status") == "running")


def pick_next(queue):
    max_attempts = int(os.environ.get("MAX_ATTEMPTS", "3"))
    max_running_per_collection = int(os.environ.get("MAX_RUNNING_PER_COLLECTION", "1"))
    pending = [item for item in queue.get("items", []) if item.get("status") == "pending" and int(item.get("attempts") or 0) < max_attempts and item.get("pdfAvailability", "pdf_ready") == "pdf_ready"]
    if not pending:
        return None
    collection_order = []
    for item in queue.get("items", []):
        key = item.get("collectionKey")
        if key not in collection_order:
            collection_order.append(key)
    for key in collection_order:
        if running_count(queue, key) >= max_running_per_collection:
            continue
        for item in pending:
            if item.get("collectionKey") == key:
                return item
    return None


def init_queue():
    config = load_json(os.environ["CONFIG_FILE"], {})
    queue_file = os.environ["QUEUE_FILE"]
    old = load_json(queue_file, {})
    if old and os.environ.get("REBUILD_QUEUE") != "1":
        queue = old
    else:
        queue = merge_progress(build_queue(config), old)
        save_json(queue_file, queue)
        write_excluded_reports(queue_file, queue)
    summary = queue_summary(queue, queue_file)
    if queue.get("excludedPdf") is not None:
        summary.update(write_excluded_reports(queue_file, queue))
    return summary


def prepare():
    queue_file = os.environ["QUEUE_FILE"]
    worker_id = os.environ["WORKER_ID"]
    run_id = os.environ["RUN_ID"]
    queue = load_json(queue_file, {})
    if not queue:
        raise RuntimeError("Queue does not exist. Run -QueueOnly first.")
    reset_stale(queue)
    selected = pick_next(queue)
    if not selected:
        counts, _, _ = status_counts(queue)
        summary = queue_summary(queue, queue_file, include_excluded_preview=False)
        summary.update({"allCompleted": counts.get("pending", 0) == 0 and counts.get("running", 0) == 0, "selected": None})
        queue["updatedAt"] = now()
        save_json(queue_file, queue)
        return summary
    selected["status"] = "running"
    selected["attempts"] = int(selected.get("attempts") or 0) + 1
    selected["workerId"] = worker_id
    selected["startedAt"] = now()
    selected["runId"] = run_id
    selected["lastError"] = None
    selected["failureCode"] = None
    queue["updatedAt"] = now()
    save_json(queue_file, queue)
    summary = queue_summary(queue, queue_file, include_excluded_preview=False)
    summary.update({"allCompleted": False, "selected": selected})
    return summary


def finalize():
    queue_file = os.environ["QUEUE_FILE"]
    result_file = os.environ["RESULT_FILE"]
    selection_file = os.environ["SELECTION_FILE"]
    queue = load_json(queue_file, {})
    result = load_json(result_file, None)
    selection = load_json(selection_file, None)
    if not result:
        raise RuntimeError(f"Missing result JSON: {result_file}")
    if result.get("status") != "completed":
        raise RuntimeError(f"Codex result is not completed: {result}")
    expected = selection.get("selected", {}) if selection else {}
    item_key = result.get("itemKey")
    collection_key = expected.get("collectionKey")
    expected_run_id = expected.get("runId")
    result_run_id = result.get("runId")
    if not expected_run_id or not result_run_id or str(result_run_id) != str(expected_run_id):
        raise RuntimeError(f"Result runId mismatch: {result_run_id} != {expected_run_id}")
    if item_key != expected.get("itemKey"):
        raise RuntimeError(f"Result itemKey mismatch: {item_key} != {expected.get('itemKey')}")
    output_file = result.get("outputFile")
    if not output_file or not Path(output_file).exists():
        raise RuntimeError(f"Output note file does not exist: {output_file}")
    structured_file = result.get("structuredFile")
    if structured_file and not Path(structured_file).exists():
        raise RuntimeError(f"Structured reading note file does not exist: {structured_file}")
    matched_item = None
    for item in queue.get("items", []):
        if item.get("collectionKey") == collection_key and item.get("itemKey") == item_key:
            matched_item = item
            break
    if matched_item is None:
        raise RuntimeError(f"Item not found in queue: {item_key}")
    if matched_item.get("status") != "running" or str(matched_item.get("runId")) != str(expected_run_id):
        raise RuntimeError(f"Queue lease no longer belongs to runId {expected_run_id}: current status={matched_item.get('status')} runId={matched_item.get('runId')}")
    for item in queue.get("items", []):
        if item is matched_item:
            item["status"] = "done"
            item["finishedAt"] = now()
            item["outputFile"] = output_file
            item["structuredFile"] = structured_file
            item["lastError"] = None
            item["failureCode"] = None
            item["workerId"] = None
            item["runId"] = None
            item["resultFile"] = result_file
            break
    queue["updatedAt"] = now()
    save_json(queue_file, queue)
    return {"updated": item_key, "runId": result_run_id, "outputFile": output_file, "structuredFile": structured_file}


def fail():
    queue_file = os.environ["QUEUE_FILE"]
    selection_file = os.environ["SELECTION_FILE"]
    error_message = os.environ.get("QUEUE_ERROR", "Codex run failed")
    error_code = os.environ.get("QUEUE_ERROR_CODE", "worker_failed")
    max_attempts = int(os.environ.get("MAX_ATTEMPTS", "3"))
    queue = load_json(queue_file, {})
    selection = load_json(selection_file, None)
    expected = selection.get("selected", {}) if selection else {}
    item_key = expected.get("itemKey")
    collection_key = expected.get("collectionKey")
    expected_run_id = expected.get("runId")
    requested_run_id = os.environ.get("RUN_ID")
    if expected_run_id and requested_run_id and str(expected_run_id) != str(requested_run_id):
        raise RuntimeError(f"Failure runId mismatch: {requested_run_id} != {expected_run_id}")
    if item_key:
        for item in queue.get("items", []):
            if item.get("collectionKey") == collection_key and item.get("itemKey") == item_key and item.get("status") == "running":
                if expected_run_id and str(item.get("runId")) != str(expected_run_id):
                    raise RuntimeError(f"Queue lease no longer belongs to runId {expected_run_id}: current runId={item.get('runId')}")
                if int(item.get("attempts") or 0) >= max_attempts:
                    item["status"] = "failed"
                else:
                    item["status"] = "pending"
                item["lastError"] = error_message
                item["failureCode"] = error_code
                item["failedAt"] = now()
                item["workerId"] = None
                item["runId"] = None
                break
    queue["updatedAt"] = now()
    save_json(queue_file, queue)
    return {"resetOrFailed": item_key, "error": error_message, "failureCode": error_code}


def main():
    mode = os.environ.get("QUEUE_MODE")
    selection_file = os.environ.get("SELECTION_FILE")
    if mode == "init":
        summary = init_queue()
    elif mode == "status":
        queue_file = os.environ["QUEUE_FILE"]
        queue = load_json(queue_file, {})
        summary = queue_summary(queue, queue_file)
    elif mode == "prepare":
        summary = prepare()
    elif mode == "finalize":
        summary = finalize()
    elif mode == "fail":
        summary = fail()
    else:
        raise RuntimeError(f"Unknown QUEUE_MODE: {mode}")
    if selection_file:
        save_json(selection_file, summary)
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
