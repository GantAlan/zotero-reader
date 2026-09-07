#!/usr/bin/env python3
"""Validate one structured Zotero reading-note JSON file without third-party packages."""
import argparse
import json
import sys
from pathlib import Path


def fail(message):
    raise ValueError(message)


def validate(record):
    if not isinstance(record, dict):
        fail("record must be an object")
    required = ["schemaVersion", "itemKey", "attachmentKey", "title", "generatedAt", "noteFile", "chunks", "evidence"]
    for key in required:
        if key not in record:
            fail(f"missing required field: {key}")
    if record["schemaVersion"] != 1:
        fail("schemaVersion must be 1")
    for key in ("itemKey", "attachmentKey", "noteFile"):
        if not isinstance(record[key], str) or not record[key].strip():
            fail(f"{key} must be a non-empty string")
    if not isinstance(record["chunks"], list):
        fail("chunks must be an array")
    if not record["chunks"]:
        fail("chunks must contain at least one chunk summary")
    if not isinstance(record["evidence"], list):
        fail("evidence must be an array")
    if not record["evidence"]:
        fail("evidence must contain at least one anchored claim")
    chunk_ids = set()
    page_by_chunk = {}
    for index, chunk in enumerate(record["chunks"]):
        if not isinstance(chunk, dict):
            fail(f"chunks[{index}] must be an object")
        for key in ("chunkId", "section", "pageStart", "pageEnd", "summary"):
            if key not in chunk:
                fail(f"chunks[{index}] missing {key}")
        if not isinstance(chunk["chunkId"], str) or not chunk["chunkId"]:
            fail(f"chunks[{index}].chunkId must be a string")
        if chunk["chunkId"] in chunk_ids:
            fail(f"duplicate chunkId: {chunk['chunkId']}")
        chunk_ids.add(chunk["chunkId"])
        if chunk["section"] is not None and not isinstance(chunk["section"], str):
            fail(f"chunks[{index}].section must be a string or null")
        if not isinstance(chunk["pageStart"], int) or not isinstance(chunk["pageEnd"], int) or chunk["pageStart"] < 1 or chunk["pageEnd"] < chunk["pageStart"]:
            fail(f"invalid page range for chunk {chunk['chunkId']}")
        page_by_chunk[chunk["chunkId"]] = (chunk["pageStart"], chunk["pageEnd"])
    evidence_ids = set()
    for index, evidence in enumerate(record["evidence"]):
        if not isinstance(evidence, dict):
            fail(f"evidence[{index}] must be an object")
        for key in ("evidenceId", "claim", "section", "chunkIds", "pageStart", "pageEnd"):
            if key not in evidence:
                fail(f"evidence[{index}] missing {key}")
        if evidence["section"] is not None and not isinstance(evidence["section"], str):
            fail(f"evidence[{index}].section must be a string or null")
        evidence_id = evidence["evidenceId"]
        if evidence_id in evidence_ids:
            fail(f"duplicate evidenceId: {evidence_id}")
        evidence_ids.add(evidence_id)
        chunk_refs = evidence["chunkIds"]
        if not isinstance(chunk_refs, list) or not chunk_refs:
            fail(f"evidence[{index}].chunkIds must be a non-empty array")
        for chunk_id in chunk_refs:
            if chunk_id not in chunk_ids:
                fail(f"evidence[{index}] references unknown chunk: {chunk_id}")
        if not isinstance(evidence["pageStart"], int) or not isinstance(evidence["pageEnd"], int) or evidence["pageEnd"] < evidence["pageStart"]:
            fail(f"invalid page range for evidence {evidence_id}")
        lower = min(page_by_chunk[c][0] for c in chunk_refs)
        upper = max(page_by_chunk[c][1] for c in chunk_refs)
        if evidence["pageStart"] < lower or evidence["pageEnd"] > upper:
            fail(f"evidence {evidence_id} page range is outside its chunk range")
    return {"ok": True, "itemKey": record["itemKey"], "chunkCount": len(record["chunks"]), "evidenceCount": len(record["evidence"])}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("record")
    args = parser.parse_args()
    record = json.loads(Path(args.record).read_text(encoding="utf-8-sig"))
    result = validate(record)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"reading_note_schema_invalid: {exc}", file=sys.stderr)
        raise SystemExit(1)
