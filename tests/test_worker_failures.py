import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
QUEUE_MANAGER = REPO / "assets" / "package-template" / "scripts" / "pool-queue-manager.py"


class WorkerFailureTests(unittest.TestCase):
    def test_finalize_rejects_stale_run_id_lease(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            queue_path = root / "queue.json"
            selection_path = root / "selection.json"
            result_path = root / "result.json"
            output_path = root / "note.md"
            output_path.write_text("# note", encoding="utf-8")
            queue = {"items": [{"collectionKey": "C1", "itemKey": "I1", "status": "running", "attempts": 1, "workerId": "worker-01", "runId": "run-2"}]}
            queue_path.write_text(json.dumps(queue), encoding="utf-8")
            selection_path.write_text(json.dumps({"selected": {"collectionKey": "C1", "itemKey": "I1", "runId": "run-1"}}), encoding="utf-8")
            result_path.write_text(json.dumps({"status": "completed", "itemKey": "I1", "runId": "run-1", "outputFile": str(output_path)}), encoding="utf-8")
            env = os.environ.copy()
            env.update({"QUEUE_MODE": "finalize", "QUEUE_FILE": str(queue_path), "SELECTION_FILE": str(selection_path), "RESULT_FILE": str(result_path)})
            result = subprocess.run([sys.executable, str(QUEUE_MANAGER)], env=env, capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Queue lease", result.stderr)
            self.assertEqual(json.loads(queue_path.read_text(encoding="utf-8"))["items"][0]["status"], "running")

    def test_pdf_extract_failure_is_recorded_after_max_attempts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            queue_path = root / "queue.json"
            selection_path = root / "selection.json"
            queue = {"items": [{"collectionKey": "C1", "itemKey": "I1", "status": "running", "attempts": 3, "workerId": "worker-01", "runId": "run-1"}]}
            queue_path.write_text(json.dumps(queue), encoding="utf-8")
            selection_path.write_text(json.dumps({"selected": queue["items"][0]}), encoding="utf-8")
            env = os.environ.copy()
            env.update({"QUEUE_MODE": "fail", "QUEUE_FILE": str(queue_path), "SELECTION_FILE": str(selection_path), "QUEUE_ERROR": "pdf_extract_failed: no text", "QUEUE_ERROR_CODE": "pdf_extract_failed", "MAX_ATTEMPTS": "3"})
            result = subprocess.run([sys.executable, str(QUEUE_MANAGER)], env=env, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            updated = json.loads(queue_path.read_text(encoding="utf-8"))
            self.assertEqual(updated["items"][0]["status"], "failed")
            self.assertEqual(updated["items"][0]["failureCode"], "pdf_extract_failed")


if __name__ == "__main__":
    unittest.main()
