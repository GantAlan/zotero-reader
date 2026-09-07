#!/usr/bin/env python3
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeChatHandler(BaseHTTPRequestHandler):
    status = 200
    response_text = "BEGIN_READING_NOTE_MARKDOWN\n# mock\nEND_READING_NOTE_MARKDOWN"
    request_count = 0

    def log_message(self, format, *args):
        return

    def do_POST(self):
        type(self).request_count += 1
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        if type(self).status != 200:
            body = json.dumps({"error": "mock failure"}).encode("utf-8")
            self.send_response(type(self).status)
        else:
            body = json.dumps({"choices": [{"message": {"content": type(self).response_text}}]}).encode("utf-8")
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=23130)
    parser.add_argument("--status", type=int, default=200)
    parser.add_argument("--response", default=FakeChatHandler.response_text)
    args = parser.parse_args()
    FakeChatHandler.status = args.status
    FakeChatHandler.response_text = args.response
    server = ThreadingHTTPServer(("127.0.0.1", args.port), FakeChatHandler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
