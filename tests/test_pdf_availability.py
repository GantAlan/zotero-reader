import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
TEMPLATE = REPO / "assets" / "package-template"
QUEUE_MANAGER = TEMPLATE / "scripts" / "pool-queue-manager.py"
sys.path.insert(0, str(HERE / "fixtures"))
from mock_zotero_api import create_server  # noqa: E402


class PdfAvailabilityTests(unittest.TestCase):
    def test_queue_classifies_local_pdf_states(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ready = root / "ready.pdf"
            ready.write_bytes(b"%PDF-1.4 mock")
            server, _ = create_server(ready)
            import threading
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                config_path = root / "config.json"
                queue_path = root / "queue.json"
                config = {"collections": [{"top": "Mock", "name": "Mock Collection", "key": "C1", "pathParts": ["Mock", "Mock Collection"]}]}
                config_path.write_text(json.dumps(config), encoding="utf-8")
                env = os.environ.copy()
                env.update({"ZOTERO_LOCAL_BASE_URL": f"http://127.0.0.1:{server.server_address[1]}", "QUEUE_MODE": "init", "CONFIG_FILE": str(config_path), "QUEUE_FILE": str(queue_path), "SELECTION_FILE": str(root / "selection.json"), "REBUILD_QUEUE": "1"})
                result = subprocess.run([sys.executable, str(QUEUE_MANAGER)], env=env, capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                queue = json.loads(queue_path.read_text(encoding="utf-8"))
                self.assertEqual(queue["total"], 2)
                self.assertEqual(queue["pdfAvailabilityCounts"]["pdf_ready"], 2)
                self.assertEqual(queue["excludedNoPdfCount"], 1)
                self.assertEqual(queue["items"][1]["attachmentKey"], "A_MULTI_READY")
                reasons = {item["reason"] for item in queue["excludedPdf"]}
                self.assertEqual(reasons, {"no_attachment", "unsupported_file", "attachment_not_local", "file_missing"})
            finally:
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    unittest.main()
