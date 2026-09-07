#!/usr/bin/env python3
"""Idempotently write structured study records to JSONL files."""
import argparse
import json
from pathlib import Path


def read_jsonl(path):
    if not path.exists():
        return []
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            rows.append(json.loads(line))
    return rows


def write_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    tmp.replace(path)


def upsert(path, row, key):
    rows = read_jsonl(path)
    replaced = False
    for index, existing in enumerate(rows):
        if existing.get(key) == row.get(key):
            rows[index] = row
            replaced = True
            break
    if not replaced:
        rows.append(row)
    rows.sort(key=lambda item: str(item.get(key, "")))
    write_jsonl(path, rows)


def replace_for_paper(path, rows_to_keep, item_key, collection_key):
    rows = read_jsonl(path)
    filtered = [
        row for row in rows
        if not (row.get("itemKey") == item_key and row.get("collectionKey") == collection_key)
    ]
    rows = filtered + rows_to_keep
    rows.sort(key=lambda item: str(item.get("recordKey", "")))
    write_jsonl(path, rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--record-file", required=True)
    parser.add_argument("--data-root", required=True)
    args = parser.parse_args()
    record = json.loads(Path(args.record_file).read_text(encoding="utf-8-sig"))
    data_root = Path(args.data_root)
    paper = {
        "schemaVersion": 1,
        "recordType": "paper",
        "recordKey": f"{record.get('collectionKey') or ''}:{record['itemKey']}",
        "collectionKey": record.get("collectionKey"),
        "collectionPath": record.get("collectionPath"),
        "itemKey": record["itemKey"],
        "attachmentKey": record["attachmentKey"],
        "title": record.get("title"),
        "generatedAt": record.get("generatedAt"),
        "noteFile": record.get("noteFile"),
        "chunkCount": len(record.get("chunks", [])),
        "evidenceCount": len(record.get("evidence", [])),
    }
    upsert(data_root / "papers.jsonl", paper, "recordKey")
    evidence_path = data_root / "evidence.jsonl"
    evidence_rows = []
    for index, evidence in enumerate(record.get("evidence", []), start=1):
        evidence_rows.append({
            "schemaVersion": 1,
            "recordType": "evidence",
            "recordKey": f"{record.get('collectionKey') or ''}:{record['itemKey']}:{evidence.get('evidenceId') or index}",
            "collectionKey": record.get("collectionKey"),
            "itemKey": record["itemKey"],
            "title": record.get("title"),
            "noteFile": record.get("noteFile"),
            **evidence,
        })
    replace_for_paper(evidence_path, evidence_rows, record["itemKey"], record.get("collectionKey"))
    print(json.dumps({"ok": True, "paper": paper["recordKey"], "evidenceCount": len(evidence_rows)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
