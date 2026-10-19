"""Bounded, loopback-only test service. Logs assertions, never request bodies or keys."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

output = Path(sys.argv[1])
expected_note = '今天想到可以把手表录音作为随手记录的入口。录完后自动传到手机，再把语音整理成可搜索的笔记。'
checks = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert self.path == '/v1/chat/completions'
        assert self.headers['Authorization'] == 'Bearer fixture-key-not-real'
        content = body['messages'][-1]['content']
        model = body['model']
        assert content in ('Reply with OK.', expected_note)
        assert model in ('fixture-model', 'unauthorized-model')
        checks.append({'fixed_probe': content == 'Reply with OK.', 'summary_text': content == expected_note, 'auth_failure': model == 'unauthorized-model'})
        output.write_text(json.dumps(checks))
        status = 401 if model == 'unauthorized-model' else 200
        payload = json.dumps({'choices': [{'message': {'content': 'OK' if content == 'Reply with OK.' else '测试总结：保存想法，周五复盘。'}, 'finish_reason': 'stop'}]}).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

server = HTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
