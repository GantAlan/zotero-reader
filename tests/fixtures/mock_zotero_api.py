#!/usr/bin/env python3
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def item(key, title, attachment_key=None, attachment_title=None):
    return {"key": key, "data": {"key": key, "itemType": "journalArticle", "title": title, "dateAdded": "2025-01-01 00:00:00", "date": "2025", "creators": [{"firstName": "Test", "lastName": "Author"}], "children": attachment_key and [attachment_key] or []}}


def attachment(key, title, filename, content_type="application/pdf"):
    return {"key": key, "data": {"key": key, "itemType": "attachment", "title": title, "filename": filename, "contentType": content_type}}


class MockZoteroState:
    def __init__(self, ready_path):
        self.ready_path = Path(ready_path).resolve()
        self.items = [
            item("I_READY", "Ready paper", "A_READY", "ready.pdf"),
            item("I_NO_ATTACHMENT", "No attachment paper"),
            item("I_UNSUPPORTED", "Unsupported paper", "A_UNSUPPORTED", "slides.pptx"),
            item("I_REMOTE", "Remote PDF paper", "A_REMOTE", "remote.pdf"),
            item("I_MISSING", "Missing PDF paper", "A_MISSING", "missing.pdf"),
            item("I_MULTI", "Multiple PDF paper", "A_MULTI_REMOTE", "remote-first.pdf"),
        ]
        self.children = {
            "I_READY": [attachment("A_READY", "ready.pdf", "ready.pdf")],
            "I_NO_ATTACHMENT": [],
            "I_UNSUPPORTED": [attachment("A_UNSUPPORTED", "slides.pptx", "slides.pptx", "application/vnd.ms-powerpoint")],
            "I_REMOTE": [attachment("A_REMOTE", "remote.pdf", "remote.pdf")],
            "I_MISSING": [attachment("A_MISSING", "missing.pdf", "missing.pdf")],
            "I_MULTI": [attachment("A_MULTI_REMOTE", "remote-first.pdf", "remote-first.pdf"), attachment("A_MULTI_READY", "ready-second.pdf", "ready-second.pdf")],
        }
        self.urls = {"A_READY": self.ready_path.as_uri(), "A_REMOTE": "https://example.invalid/remote.pdf", "A_MISSING": (self.ready_path.parent / "missing.pdf").resolve().as_uri(), "A_MULTI_REMOTE": "https://example.invalid/remote-first.pdf", "A_MULTI_READY": self.ready_path.as_uri()}


class MockZoteroHandler(BaseHTTPRequestHandler):
    state = None

    def log_message(self, format, *args):
        return

    def send_json(self, value, status=200, headers=None):
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if headers:
            for key, value in headers.items():
                self.send_header(key, str(value))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        state = type(self).state
        if path.endswith("/collections"):
            self.send_json([{"key": "C1", "data": {"name": "Mock Collection", "parentCollection": False}}], headers={"Total-Results": 1})
            return
        if path.endswith("/collections/C1/items/top"):
            self.send_json(state.items, headers={"Total-Results": len(state.items)})
            return
        if "/items/" in path and path.endswith("/children"):
            key = path.split("/items/")[1].split("/")[0]
            self.send_json(state.children.get(key, []), headers={"Total-Results": len(state.children.get(key, []))})
            return
        if "/items/" in path and path.endswith("/file/view/url"):
            key = path.split("/items/")[1].split("/")[0]
            if key not in state.urls:
                self.send_json({"error": "not found"}, status=404)
                return
            body = json.dumps(state.urls[key]).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path.endswith("/items"):
            self.send_json([], headers={"Total-Results": 0})
            return
        self.send_json({"error": "not found", "path": path}, status=404)


def create_server(ready_path):
    state = MockZoteroState(ready_path)
    MockZoteroHandler.state = state
    server = ThreadingHTTPServer(("127.0.0.1", 0), MockZoteroHandler)
    return server, state


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=23129)
    parser.add_argument("--ready-path", required=True)
    args = parser.parse_args()
    MockZoteroHandler.state = MockZoteroState(args.ready_path)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), MockZoteroHandler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
