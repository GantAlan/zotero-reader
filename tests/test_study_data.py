import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TEMPLATE = REPO / "assets" / "package-template"
VALIDATOR = TEMPLATE / "scripts" / "validate-reading-note.py"
WRITER = TEMPLATE / "scripts" / "write-study-data.py"


class StudyDataTests(unittest.TestCase):
    def test_schema_and_jsonl_writer_are_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            record_path = root / "note.json"
            record = {"schemaVersion": 1, "itemKey": "I1", "attachmentKey": "A1", "title": "标题", "generatedAt": "2026/09/07 12:00:00", "noteFile": "study-paper/note.md", "collectionKey": "C1", "collectionPath": "Top / Child", "chunks": [{"chunkId": "chunk-0001-p0001-p0002", "pageStart": 1, "pageEnd": 2, "section": "Introduction", "summary": "summary"}], "evidence": [{"evidenceId": "e1", "claim": "claim", "quote": "quote", "chunkIds": ["chunk-0001-p0001-p0002"], "pageStart": 1, "pageEnd": 1, "section": "Introduction"}]}
            record_path.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
            valid = subprocess.run([sys.executable, str(VALIDATOR), str(record_path)], capture_output=True, text=True, check=False)
            self.assertEqual(valid.returncode, 0, valid.stderr)
            for _ in range(2):
                written = subprocess.run([sys.executable, str(WRITER), "--record-file", str(record_path), "--data-root", str(root / "study-data")], capture_output=True, text=True, check=False)
                self.assertEqual(written.returncode, 0, written.stderr)
            record["evidence"] = []
            record_path.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
            written = subprocess.run([sys.executable, str(WRITER), "--record-file", str(record_path), "--data-root", str(root / "study-data")], capture_output=True, text=True, check=False)
            self.assertEqual(written.returncode, 0, written.stderr)
            papers = (root / "study-data" / "papers.jsonl").read_text(encoding="utf-8").splitlines()
            evidence = (root / "study-data" / "evidence.jsonl").read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(papers), 1)
            self.assertEqual(len(evidence), 0)


if __name__ == "__main__":
    unittest.main()
