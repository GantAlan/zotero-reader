import csv
import json
import os
import urllib.parse
import urllib.request
from collections import OrderedDict
from datetime import datetime, timedelta
from pathlib import Path

BASE = "http://127.0.0.1:23119/api/users/0"
HEADERS = {"Zotero-API-Version": "3"}
BIB_TYPES = {"journalArticle", "conferencePaper", "thesis", "bookSection", "book", "preprint", "report"}


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
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(url, headers=HEADERS)
    with opener.open(req, timeout=30) as response:
        body = response.read().decode("utf-8", errors="replace")
        return json.loads(body) if body else None, dict(response.headers)


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


def first_pdf_attachment(item_key):
    children = fetch_all(f"/items/{item_key}/children", {"format": "json"})
    for child in children:
        data = child.get("data", {})
        if data.get("itemType") != "attachment":
            continue
        content_type = (data.get("contentType") or "").lower()
        title = (data.get("title") or "").lower()
        filename = (data.get("filename") or "").lower()
        path = (data.get("path") or "").lower()
        if content_type == "application/pdf" or title.endswith(".pdf") or filename.endswith(".pdf") or path.endswith(".pdf") or title == "pdf":
            return {
                "attachmentKey": child.get("key"),
                "attachmentTitle": data.get("title"),
                "attachmentContentType": data.get("contentType"),
            }
    return None


def collection_items(collection):
    zotero_items = fetch_all(
        f"/collections/{collection['key']}/items/top",
        {"format": "json", "sort": "dateAdded", "direction": "desc"},
    )
    output = []
    excluded = []
    raw_top_count = len(zotero_items)
    bibliographic_count = 0
    for item in zotero_items:
        data = item.get("data", {})
        item_type = data.get("itemType")
        if item_type not in BIB_TYPES:
            continue
        bibliographic_count += 1
        pdf = first_pdf_attachment(item.get("key"))
        if not pdf:
            excluded.append({
                "itemKey": item.get("key"),
                "title": data.get("title"),
                "dateAdded": data.get("dateAdded"),
                "collectionKey": collection["key"],
                "collectionName": collection.get("name"),
                "topCollectionName": collection.get("top"),
                "pathParts": collection.get("pathParts") or [collection.get("top"), collection.get("name")],
                "reason": "no PDF attachment",
            })
            continue
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
            "attachmentContentType": pdf.get("attachmentContentType"),
            "itemType": item_type,
            "title": data.get("title"),
            "publicationTitle": data.get("publicationTitle"),
            "date": data.get("date"),
            "year": year_from_date(data.get("date")),
            "dateAdded": data.get("dateAdded"),
            "DOI": data.get("DOI"),
            "creators": creators(data),
            "status": "pending",
            "attempts": 0,
            "workerId": None,
            "outputFile": None,
            "startedAt": None,
            "finishedAt": None,
            "lastError": None,
        })
    return output, excluded, bibliographic_count, raw_top_count


def build_queue(config):
    items = []
    excluded = []
    collection_sources = []
    total_zotero_items = 0
    total_top_items = 0
    for collection in config.get("collections", []):
        collection_queue, collection_excluded, bibliographic_count, raw_top_count = collection_items(collection)
        items.extend(collection_queue)
        excluded.extend(collection_excluded)
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
            "excludedNoPdfCount": len(collection_excluded),
        })
    for index, item in enumerate(items, start=1):
        item["globalIndex"] = index
    return {
        "schemaVersion": 2,
        "queueType": "global-pool",
        "orderBy": "configured_collection_order_then_dateAdded_desc",
        "createdAt": now(),
        "updatedAt": now(),
        "total": len(items),
        "pdfBackedItems": len(items),
        "totalZoteroItems": total_zotero_items,
        "totalTopItems": total_top_items,
        "excludedNoPdfCount": len(excluded),
        "excludedNoPdf": excluded,
        "collectionSources": collection_sources,
        "items": items,
    }


def merge_progress(new_queue, old_queue):
    if not old_queue:
        return new_queue
    old_by_pair = {(item.get("collectionKey"), item.get("itemKey")): item for item in old_queue.get("items", [])}
    progress_fields = [
        "status", "attempts", "workerId", "outputFile", "startedAt", "finishedAt",
        "lastError", "resultFile", "failedAt", "runId"
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
    for item in queue.get("items", []):
        status = item.get("status", "pending")
        counts[status] = counts.get(status, 0) + 1
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
    return counts, list(by_collection.values())


def enrich_collection_status(queue, by_collection):
    by_key = OrderedDict((item.get("collectionKey"), dict(item)) for item in by_collection)
    for source in queue.get("collectionSources", []) or []:
        key = source.get("collectionKey")
        current = by_key.get(key)
        if current is None:
            current = {
                "topCollectionName": source.get("topCollectionName"),
                "collectionName": source.get("collectionName"),
                "collectionKey": key,
                "total": 0,
                "pending": 0,
                "running": 0,
                "done": 0,
                "failed": 0,
            }
            by_key[key] = current
        current["totalTopItems"] = source.get("totalTopItems")
        current["totalZoteroItems"] = source.get("totalZoteroItems")
        current["pdfBackedItems"] = source.get("pdfBackedItems", current.get("total", 0))
        current["excludedNoPdfCount"] = source.get("excludedNoPdfCount", 0)
    return list(by_key.values())


def queue_summary(queue, queue_file=None, include_excluded_preview=True):
    queue = queue or {}
    counts, by_collection = status_counts(queue)
    by_collection = enrich_collection_status(queue, by_collection)
    total = queue.get("total", len(queue.get("items", [])))
    excluded_count = queue.get("excludedNoPdfCount", len(queue.get("excludedNoPdf", []) or []))
    summary = {
        "queueFile": queue_file,
        "total": total,
        "pdfBackedItems": queue.get("pdfBackedItems", total),
        "totalZoteroItems": queue.get("totalZoteroItems", (total or 0) + (excluded_count or 0)),
        "totalTopItems": queue.get("totalTopItems"),
        "excludedNoPdfCount": excluded_count,
        "statusCounts": counts,
        "collections": by_collection,
    }
    if include_excluded_preview:
        summary["excludedNoPdf"] = (queue.get("excludedNoPdf", []) or [])[:100]
    return summary


def write_excluded_reports(queue_file, queue):
    excluded = queue.get("excludedNoPdf", []) or []
    queue_path = Path(queue_file)
    report_md = queue_path.parent / "excluded-no-pdf-report.md"
    report_csv = queue_path.parent / "excluded-no-pdf-report.csv"
    lines = [
        "# Excluded Zotero Items Without PDF",
        "",
        f"Generated: {now()}",
        f"Count: {len(excluded)}",
        "",
    ]
    if excluded:
        lines.extend(["| itemKey | Collection | Date Added | Title |", "|---|---|---|---|"])
        for item in excluded:
            collection_path = " / ".join(item.get("pathParts") or [item.get("topCollectionName"), item.get("collectionName")])
            title = (item.get("title") or "").replace("|", "\\|")
            lines.append(f"| {item.get('itemKey')} | {collection_path} | {item.get('dateAdded') or ''} | {title} |")
    else:
        lines.append("No PDF-less bibliographic items were excluded.")
    report_md.write_text("\n".join(lines) + "\n", encoding="utf-8")
    with report_csv.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["itemKey", "collectionPath", "dateAdded", "title", "reason"])
        writer.writeheader()
        for item in excluded:
            collection_path = " / ".join(item.get("pathParts") or [item.get("topCollectionName"), item.get("collectionName")])
            writer.writerow({
                "itemKey": item.get("itemKey"),
                "collectionPath": collection_path,
                "dateAdded": item.get("dateAdded"),
                "title": item.get("title"),
                "reason": item.get("reason") or "no PDF attachment",
            })
    return {"excludedNoPdfReportMd": str(report_md), "excludedNoPdfReportCsv": str(report_csv)}


def reset_stale(queue):
    lease_hours = int(os.environ.get("LEASE_HOURS", "8"))
    cutoff = datetime.now() - timedelta(hours=lease_hours)
    for item in queue.get("items", []):
        if item.get("status") != "running":
            continue
        started = parse_time(item.get("startedAt"))
        if started and started < cutoff:
            item["status"] = "pending"
            item["lastError"] = "Reset stale running lease."
            item["workerId"] = None


def running_count(queue, collection_key):
    return sum(
        1 for item in queue.get("items", [])
        if item.get("collectionKey") == collection_key and item.get("status") == "running"
    )


def pick_next(queue):
    max_attempts = int(os.environ.get("MAX_ATTEMPTS", "3"))
    max_running_per_collection = int(os.environ.get("MAX_RUNNING_PER_COLLECTION", "1"))
    pending = [
        item for item in queue.get("items", [])
        if item.get("status") == "pending" and int(item.get("attempts") or 0) < max_attempts
    ]
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
    if queue.get("excludedNoPdf") is not None:
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
        counts, by_collection = status_counts(queue)
        summary = queue_summary(queue, queue_file, include_excluded_preview=False)
        summary.update({
            "allCompleted": counts.get("pending", 0) == 0 and counts.get("running", 0) == 0,
            "selected": None,
        })
        queue["updatedAt"] = now()
        save_json(queue_file, queue)
        return summary
    selected["status"] = "running"
    selected["attempts"] = int(selected.get("attempts") or 0) + 1
    selected["workerId"] = worker_id
    selected["startedAt"] = now()
    selected["runId"] = run_id
    selected["lastError"] = None
    queue["updatedAt"] = now()
    save_json(queue_file, queue)
    counts, by_collection = status_counts(queue)
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
    if item_key != expected.get("itemKey"):
        raise RuntimeError(f"Result itemKey mismatch: {item_key} != {expected.get('itemKey')}")
    output_file = result.get("outputFile")
    if not output_file or not Path(output_file).exists():
        raise RuntimeError(f"Output note file does not exist: {output_file}")
    for item in queue.get("items", []):
        if item.get("collectionKey") == collection_key and item.get("itemKey") == item_key:
            item["status"] = "done"
            item["finishedAt"] = now()
            item["outputFile"] = output_file
            item["lastError"] = None
            item["workerId"] = None
            item["resultFile"] = result_file
            break
    else:
        raise RuntimeError(f"Item not found in queue: {item_key}")
    queue["updatedAt"] = now()
    save_json(queue_file, queue)
    return {"updated": item_key, "outputFile": output_file}


def fail():
    queue_file = os.environ["QUEUE_FILE"]
    selection_file = os.environ["SELECTION_FILE"]
    error_message = os.environ.get("QUEUE_ERROR", "Codex run failed")
    max_attempts = int(os.environ.get("MAX_ATTEMPTS", "3"))
    queue = load_json(queue_file, {})
    selection = load_json(selection_file, None)
    expected = selection.get("selected", {}) if selection else {}
    item_key = expected.get("itemKey")
    collection_key = expected.get("collectionKey")
    if item_key:
        for item in queue.get("items", []):
            if item.get("collectionKey") == collection_key and item.get("itemKey") == item_key and item.get("status") == "running":
                if int(item.get("attempts") or 0) >= max_attempts:
                    item["status"] = "failed"
                else:
                    item["status"] = "pending"
                item["lastError"] = error_message
                item["failedAt"] = now()
                item["workerId"] = None
                break
    queue["updatedAt"] = now()
    save_json(queue_file, queue)
    return {"resetOrFailed": item_key, "error": error_message}


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
