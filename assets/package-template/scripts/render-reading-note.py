#!/usr/bin/env python3
"""Render deterministic page/section/chunk evidence into a Markdown note."""
import argparse
import json
from pathlib import Path

MARKER = "## 证据锚点 / Evidence Anchors"


def quote_lines(quote):
    value = str(quote or "").strip()
    if not value:
        return []
    return [f"> {line.strip()}" for line in value.splitlines() if line.strip()]


def render(markdown, record):
    base = markdown.split(MARKER, 1)[0].rstrip()
    lines = [base, "", MARKER, "", "本节由结构化阅读结果自动生成，用于把结论连接到 PDF 页码、章节和 chunk。", ""]
    for evidence in record.get("evidence", []):
        evidence_id = evidence.get("evidenceId") or "evidence"
        claim = str(evidence.get("claim") or "未命名结论").strip()
        page_start = evidence.get("pageStart")
        page_end = evidence.get("pageEnd")
        page_text = f"p. {page_start}" if page_start == page_end else f"pp. {page_start}-{page_end}"
        section = evidence.get("section") or "未标注章节"
        chunk_ids = ", ".join(str(value) for value in evidence.get("chunkIds", []))
        lines.extend([
            f"### {evidence_id}: {claim}",
            f"- 页码 / Pages: {page_text}",
            f"- 章节 / Section: {section}",
            "- Chunk: " + chr(96) + chunk_ids + chr(96),
        ])
        quoted = quote_lines(evidence.get("quote"))
        if quoted:
            lines.append("- 原文证据 / Source evidence:")
            lines.extend(quoted)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--markdown", required=True)
    parser.add_argument("--record", required=True)
    parser.add_argument("--output")
    args = parser.parse_args()
    markdown_path = Path(args.markdown)
    record_path = Path(args.record)
    output_path = Path(args.output) if args.output else markdown_path
    markdown = markdown_path.read_text(encoding="utf-8-sig")
    record = json.loads(record_path.read_text(encoding="utf-8-sig"))
    if not record.get("evidence"):
        raise SystemExit("record contains no evidence anchors")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(render(markdown, record), encoding="utf-8")
    print(json.dumps({"ok": True, "output": str(output_path), "evidenceCount": len(record["evidence"])}, ensure_ascii=False))


if __name__ == "__main__":
    main()
