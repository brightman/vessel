"""Deterministic local HTTP fixture. No real user data or external model calls."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import sys


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.reply({"data": [{"id": "fixture"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        if self.path.startswith("/redirect/"):
            self.send_response(302)
            self.send_header("Location", "/v1/chat/completions")
            self.end_headers()
            return
        instruction = body["messages"][0]["content"]
        if body["model"] == "invalid-citation":
            content = "错误引用 [S999999]"
        elif "Markdown" in instruction:
            content = "## 概览\n已整理测试资料。 [S1]\n\n## 行动项\n原文未明确。"
        elif "Connection test" in instruction:
            content = "OK"
        else:
            content = "测试资料要点。 [S1]"
        self.reply({"choices": [{"message": {"content": content}, "finish_reason": "stop"}]})

    def reply(self, value):
        data = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
