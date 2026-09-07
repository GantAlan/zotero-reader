#!/usr/bin/env python3
"""Extract a local PDF into page-aware reading chunks."""
import argparse
import json
import re
import sys
from pathlib import Path


def load_reader():
    try:
        from pypdf import PdfReader
        return PdfReader
    except Exception:
        try:
            from PyPDF2 import PdfReader
            return PdfReader
        except Exception as exc:
            raise RuntimeError("Neither pypdf nor PyPDF2 is installed.") from exc


def clean_text(value):
    value = (value or "").replace("\x00", "")
    value = re.sub(r"[ \t]+", " ", value)
    value = re.sub(r"\n{3,}", "\n\n", value)
    return value.strip()


def detect_heading(lines):
    for raw in lines[:12]:
        line = raw.strip()
        if not line or len(line) > 120:
            continue
        if re.match(r"^(?:\d+(?:\.\d+)*[.)]?\s+)?[A-Z][A-Za-z0-9][A-Za-z0-9 :&/()'_-]{2,}$", line):
            return line
        if re.match(r"^(?:\d+(?:\.\d+)*[.)]?\s+)?(?:摘要|引言|绪论|方法|结果|讨论|结论|实验|材料|数据|附录|参考文献)", line):
            return line
    return ""


def make_chunk(index, page_start, page_end, section, text, part=None):
    suffix = f"-part{part:02d}" if part else ""
    return {
        "chunkId": f"chunk-{index:04d}-p{page_start:04d}-p{page_end:04d}{suffix}",
        "pageStart": page_start,
        "pageEnd": page_end,
        "section": section or None,
        "charCount": len(text),
        "text": text,
    }


def extract(pdf_path, max_chars, overlap_chars, max_pages):
    PdfReader = load_reader()
    reader = PdfReader(str(pdf_path))
    page_records = []
    current_section = ""
    for page_number, page in enumerate(reader.pages, start=1):
        text = clean_text(page.extract_text() or "")
        if not text:
            continue
        heading = detect_heading(text.splitlines())
        if heading:
            current_section = heading
        page_records.append({"page": page_number, "section": current_section, "text": text})

    if not page_records:
        raise RuntimeError("PDF text extraction returned no text; OCR may be required.")

    chunks = []
    index = 1
    buffer = []
    buffer_chars = 0
    buffer_page_count = 0

    def flush():
        nonlocal index, buffer, buffer_chars, buffer_page_count
        if not buffer:
            return
        text = "\n\n".join(item["text"] for item in buffer).strip()
        chunks.append(make_chunk(index, buffer[0]["page"], buffer[-1]["page"], buffer[0]["section"], text))
        index += 1
        buffer = []
        buffer_chars = 0
        buffer_page_count = 0

    for page in page_records:
        page_text = page["text"]
        if len(page_text) <= max_chars:
            if buffer and (buffer_page_count >= max_pages or buffer_chars + len(page_text) > max_chars):
                previous_tail = ""
                previous_page = page["page"]
                previous_section = page["section"]
                if overlap_chars > 0 and buffer:
                    previous_text = "\n\n".join(item["text"] for item in buffer)
                    previous_tail = previous_text[-overlap_chars:]
                    previous_page = buffer[-1].get("page") or previous_page
                    previous_section = buffer[-1].get("section") or previous_section
                flush()
                marker = "[OVERLAP FROM PREVIOUS CHUNK]\n"
                available = max_chars - len(page_text)
                if previous_tail and available > len(marker):
                    overlap_text = marker + previous_tail[-min(len(previous_tail), available - len(marker)):]
                    buffer.append({"page": previous_page, "section": previous_section, "text": overlap_text})
                    buffer_chars = len(overlap_text)
            if buffer and buffer_chars + len(page_text) > max_chars:
                flush()
            buffer.append(page)
            buffer_chars += len(page_text)
            buffer_page_count += 1
            continue

        flush()
        step = max(1, max_chars - overlap_chars)
        part = 1
        start = 0
        while start < len(page_text):
            end = min(len(page_text), start + max_chars)
            piece = page_text[start:end].strip()
            chunks.append(make_chunk(index, page["page"], page["page"], page["section"], piece, part))
            index += 1
            part += 1
            if end >= len(page_text):
                break
            start += step
    flush()

    return {
        "schemaVersion": 1,
        "sourceFileName": pdf_path.name,
        "pageCount": len(reader.pages),
        "extractedPageCount": len(page_records),
        "chunkCount": len(chunks),
        "chunks": chunks,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pdf")
    parser.add_argument("output")
    parser.add_argument("--max-chars", type=int, default=18000)
    parser.add_argument("--overlap-chars", type=int, default=1200)
    parser.add_argument("--max-pages", type=int, default=4)
    args = parser.parse_args()
    if args.max_chars < 1000:
        raise SystemExit("--max-chars must be >= 1000")
    if args.overlap_chars < 0 or args.overlap_chars >= args.max_chars:
        raise SystemExit("--overlap-chars must be >= 0 and smaller than --max-chars")
    if args.max_pages < 1:
        raise SystemExit("--max-pages must be >= 1")
    pdf_path = Path(args.pdf)
    output_path = Path(args.output)
    if not pdf_path.exists():
        raise SystemExit("PDF file does not exist")
    result = extract(pdf_path, args.max_chars, args.overlap_chars, args.max_pages)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: result[k] for k in ("pageCount", "extractedPageCount", "chunkCount", "sourceFileName")}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"pdf_extract_failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
