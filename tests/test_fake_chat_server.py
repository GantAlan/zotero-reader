import json
import threading
import unittest
from http.client import HTTPConnection
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "fixtures"))
from fake_chat_server import FakeChatHandler  # noqa: E402
from http.server import ThreadingHTTPServer


class FakeChatTests(unittest.TestCase):
    def test_fake_chat_server_exposes_failure_path(self):
        FakeChatHandler.status = 503
        server = ThreadingHTTPServer(("127.0.0.1", 0), FakeChatHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            connection = HTTPConnection("127.0.0.1", server.server_address[1], timeout=5)
            connection.request("POST", "/v1/chat/completions", body=b"{}", headers={"Content-Type": "application/json"})
            response = connection.getresponse()
            self.assertEqual(response.status, 503)
            response.read()
            connection.close()
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
