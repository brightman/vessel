#!/usr/bin/env python3
"""Local synthetic Chat Completions fixture; never logs request bodies or credentials."""
import argparse
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=18763)
parser.add_argument("--report", type=Path, required=True)
arguments = parser.parse_args()
requests = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length < 1_000_000:
            self.send_error(413)
            return
        try:
            body = json.loads(self.rfile.read(length))
            material = body["messages"][-1]["content"]
            instruction = body["messages"][0]["content"]
        except (ValueError, KeyError, IndexError, TypeError):
            self.send_error(400)
            return
        checks = {
            "correct_path": self.path == "/v1/chat/completions",
            "fixture_model": body.get("model") == "meeting-fixture",
            "uncertainty_instruction": "不能证明" in instruction and "不得推断" in instruction,
            "hrv_window_instruction": "跨录音边界" in instruction and "不能从BPM推算HRV" in instruction,
            "motion_instruction": "运动上下文" in instruction and "未知不是没有活动" in instruction,
            "subjective_scope_instruction": "主观自报" in instruction and "全天心情只作同日背景" in instruction,
            "no_health_identifiers": not re.search(r"\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b", material),
            "no_device_metadata": all(value not in material for value in ["fixture.watch", "fixture.health", "Watch7,18", "Fixture", "Health（模拟数据）", "Asia/Shanghai"]),
            "evidence_or_statistics": any(value in material for value in ["证据 E", "采样事实", "HRV证据 V", "心境证据 M"]),
            "hrv_payload": "心境证据 M" in material or ("SDNN" in material and ("暂无可用" in material or ("ms" in material and "窗口" in material))),
            "motion_payload": "证据 E" not in material or "两个采样点的运动上下文" in material,
            "subjective_payload": "心境证据 M" not in material or all(value in material for value in ["本人心境记录", "本人选择的关联因素", "非AI评分"]),
            "daily_mood_no_excerpt": "心境证据 M" not in material or "全天心情，仅作背景" not in material or "时间点重合的原文：无" in material,
        }
        requests.append(checks)
        arguments.report.write_text(json.dumps({"ok": all(all(row.values()) for row in requests), "requests": requests}))
        reply = {"choices": [{"message": {"content": "fixture：同期观察需本人确认，不能据此判断情绪或因果。"}, "finish_reason": "stop"}]}
        encoded = json.dumps(reply, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler).serve_forever()
