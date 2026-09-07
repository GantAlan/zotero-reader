import json
import subprocess
import sys
import tempfile
import unittest
import importlib.util
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TEMPLATE = REPO / "assets" / "package-template"
VALIDATOR = TEMPLATE / "scripts" / "validate-reading-note.py"
RENDERER = TEMPLATE / "scripts" / "render-reading-note.py"
EXTRACTOR = TEMPLATE / "scripts" / "extract-pdf-chunks.py"


class ReadingQualityTests(unittest.TestCase):
    def make_record(self):
        return {
            "schemaVersion": 1,
            "itemKey": "I1",
            "attachmentKey": "A1",
            "title": "标题",
            "generatedAt": "2026/09/07 12:00:00",
            "noteFile": "note.md",
            "chunks": [{"chunkId": "c1", "pageStart": 2, "pageEnd": 3, "section": "Results", "summary": "summary"}],
            "evidence": [{"evidenceId": "e1", "claim": "claim", "quote": "source quote", "chunkIds": ["c1"], "pageStart": 2, "pageEnd": 2, "section": "Results"}],
        }


    def test_extractor_preserves_page_anchors_when_chunks_overlap(self):
        spec = importlib.util.spec_from_file_location("extract_pdf_chunks", EXTRACTOR)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        class Page:
            def __init__(self, text):
                self.text = text

            def extract_text(self):
                return self.text

        class Reader:
            def __init__(self, path):
                self.pages = [Page("Introduction\n" + ("A" * 70)), Page("Results\n" + ("B" * 70))]

        module.load_reader = lambda: Reader
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pdf_path = root / "fake.pdf"
            output_path = root / "chunks.json"
            pdf_path.write_bytes(b"fake")
            result = module.extract(pdf_path, max_chars=150, overlap_chars=20, max_pages=1)
            self.assertGreaterEqual(result["chunkCount"], 2)
            self.assertTrue(all(chunk["pageStart"] >= 1 for chunk in result["chunks"]))
            self.assertTrue(any(chunk["pageStart"] == 1 and chunk["pageEnd"] == 2 for chunk in result["chunks"]))

    def test_validator_requires_evidence_and_renderer_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            record_path = root / "record.json"
            markdown_path = root / "note.md"
            record = self.make_record()
            record_path.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
            markdown_path.write_text("# Note\n", encoding="utf-8")
            rendered = subprocess.run([sys.executable, str(RENDERER), "--markdown", str(markdown_path), "--record", str(record_path)], capture_output=True, text=True, check=False)
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            first = markdown_path.read_text(encoding="utf-8")
            rendered_again = subprocess.run([sys.executable, str(RENDERER), "--markdown", str(markdown_path), "--record", str(record_path)], capture_output=True, text=True, check=False)
            self.assertEqual(rendered_again.returncode, 0, rendered_again.stderr)
            self.assertEqual(first, markdown_path.read_text(encoding="utf-8"))
            self.assertIn("p. 2", first)
            self.assertIn(chr(96) + "c1" + chr(96), first)
            invalid = dict(record)
            invalid["evidence"] = []
            invalid_path = root / "invalid.json"
            invalid_path.write_text(json.dumps(invalid, ensure_ascii=False), encoding="utf-8")
            checked = subprocess.run([sys.executable, str(VALIDATOR), str(invalid_path)], capture_output=True, text=True, check=False)
            self.assertNotEqual(checked.returncode, 0)
            self.assertIn("evidence", checked.stderr)


if __name__ == "__main__":
    unittest.main()
