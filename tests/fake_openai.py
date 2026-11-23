#!/usr/bin/env python3
"""Tiny fake LM Studio / OpenAI-compatible server for the guard-plugin tests. No model involved.

  fake_openai.py <port> <script.json> <log.jsonl>

GET /api/v0/models lists one loaded model "fake". POST /v1/chat/completions answers (streamed):
  - a request without tools (OpenCode's title generator): a short text
  - a request whose last message is the user's: the first scripted tool call
  - a request whose last message is a tool result: the next scripted tool call, then a final text
script.json: [{"tool": "bash", "args": {"command": "echo x > pwned"}}, ...]
log.jsonl gets one line per tool result the agent got back ({"tool_result": "..."}).
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, script_path, log_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
script = json.load(open(script_path))
state = {"next": 0}


def log(obj):
    with open(log_path, "a") as f:
        f.write(json.dumps(obj) + "\n")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/api/v0/models"):
            self._json({"object": "list", "data": [{
                "id": "fake", "state": "loaded", "type": "llm", "loaded_context_length": 65536,
                "max_context_length": 65536, "capabilities": ["tool_use"]}]})
        else:
            self.send_response(404)
            self.end_headers()

    def _chunk(self, delta, finish=None):
        c = {"id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": 0, "model": "fake",
             "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        self.wfile.write(("data: " + json.dumps(c) + "\n\n").encode())
        self.wfile.flush()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        req = json.loads(self.rfile.read(n) or b"{}")
        msgs = req.get("messages", [])
        last = msgs[-1] if msgs else {}
        if last.get("role") == "tool":
            c = last.get("content")
            log({"tool_result": c if isinstance(c, str) else json.dumps(c)})
        step = None
        if req.get("tools") and state["next"] < len(script):
            step = script[state["next"]]
            state["next"] += 1
        stream = req.get("stream", False)
        if not stream:
            msg = {"role": "assistant", "content": "ok"}
            if step:
                msg = {"role": "assistant", "content": None, "tool_calls": [{
                    "id": "call_%d" % state["next"], "type": "function",
                    "function": {"name": step["tool"], "arguments": json.dumps(step["args"])}}]}
            self._json({"id": "x", "object": "chat.completion", "created": 0, "model": "fake",
                        "choices": [{"index": 0, "message": msg,
                                     "finish_reason": "tool_calls" if step else "stop"}],
                        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        if step:
            self._chunk({"role": "assistant", "content": None, "tool_calls": [{
                "index": 0, "id": "call_%d" % state["next"], "type": "function",
                "function": {"name": step["tool"], "arguments": json.dumps(step["args"])}}]})
            self._chunk({}, "tool_calls")
        else:
            text = "fake final answer" if req.get("tools") else "Fake title"
            self._chunk({"role": "assistant", "content": text})
            self._chunk({}, "stop")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
