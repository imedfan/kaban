#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Минимальная заглушка MCP-сервера доски Kaban (Streamable HTTP, без зависимостей).

Только stdlib, совместимо с Python 3.9 (/usr/bin/python3 из Xcode CLT).

* Слушает 127.0.0.1:<port> (по умолчанию случайный порт), endpoint /mcp.
* JSON-RPC 2.0: initialize, notifications/initialized, ping, tools/list, tools/call
  (+ пакеты-массивы). Инструменты: report_progress(text), complete_stage(summary).
* Требует `Authorization: Bearer <token>`; ожидаемый токен берётся из переменной
  окружения (--token-env, по умолчанию KABAN_RUN_TOKEN), а не из argv, чтобы он
  не светился в `ps`. --no-auth отключает проверку (для «чужого» сервера проекта).
* Каждый HTTP-запрос пишется строкой JSON в --log: метод, путь, rpc-методы,
  инструмент, аргументы инструмента (усечённые), результат проверки Bearer
  (match / mismatch / missing / empty / literal_placeholder / disabled), имена
  заголовков (без значений), User-Agent, код ответа. Сам токен не пишется никогда.
* GET /mcp -> 405 (SSE-поток не предлагаем, это разрешено спецификацией),
  DELETE /mcp -> 200 (завершение сессии), прочие пути -> 404 (включая .well-known/*).

Пример:
  KABAN_RUN_TOKEN=test python3 mcp_stub_server.py --port 0 --port-file /tmp/p --log /tmp/l.jsonl
"""
from __future__ import print_function

import argparse
import datetime
import hmac
import json
import os
import signal
import sys
import threading
import uuid

try:
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
except ImportError:  # pragma: no cover (Python < 3.7)
    print("нужен Python >= 3.7", file=sys.stderr)
    sys.exit(2)

SUPPORTED_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"]

TOOLS = [
    {
        "name": "report_progress",
        "description": "Kaban board: report progress of the current stage (short text).",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string", "description": "Progress text"}},
            "required": ["text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "complete_stage",
        "description": "Kaban board: mark the current stage as complete. Returns an acknowledgement code.",
        "inputSchema": {
            "type": "object",
            "properties": {"summary": {"type": "string", "description": "Stage summary"}},
            "required": ["summary"],
            "additionalProperties": False,
        },
    },
]


class State(object):
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.token = None
        if not args.no_auth:
            self.token = os.environ.get(args.token_env, "")
            if not self.token:
                print("mcp_stub: переменная %s пуста; задай токен или --no-auth" % args.token_env,
                      file=sys.stderr)
                sys.exit(2)
        self.sessions = set()
        self.log_f = open(args.log, "a", encoding="utf-8") if args.log else None

    def log(self, rec):
        rec["ts"] = datetime.datetime.now().astimezone().isoformat(timespec="milliseconds")
        rec["server"] = self.args.name
        line = json.dumps(rec, ensure_ascii=False, sort_keys=True)
        with self.lock:
            if self.log_f:
                self.log_f.write(line + "\n")
                self.log_f.flush()
        if self.args.verbose:
            print(line, file=sys.stderr)


def classify_auth(state, header):
    if state.token is None:
        return "disabled"
    if header is None:
        return "missing"
    h = header.strip()
    if not h.lower().startswith("bearer"):
        return "mismatch"
    val = h[6:].strip()
    if not val:
        return "empty"
    if "${" in val:
        return "literal_placeholder"  # интерполяция ${env:...} не выполнена
    if hmac.compare_digest(val.encode("utf-8"), state.token.encode("utf-8")):
        return "match"
    return "mismatch"


def rpc_error(mid, code, msg):
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": msg}}


def text_result(text, is_error=False):
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def handle_rpc(state, msg, rec):
    """Возвращает ответ (dict) или None для уведомлений/ответов клиента."""
    if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0":
        return rpc_error(None, -32600, "Invalid Request")
    method = msg.get("method")
    mid = msg.get("id")
    is_request = "id" in msg and method is not None
    if method is None:
        return None  # ответ клиента на наш запрос (мы их не шлём)
    rec.setdefault("rpc_methods", []).append(method)
    params = msg.get("params") or {}
    if not is_request:
        return None  # notifications/initialized и прочие уведомления
    if method == "initialize":
        want = params.get("protocolVersion") if isinstance(params, dict) else None
        ver = want if want in SUPPORTED_VERSIONS else SUPPORTED_VERSIONS[0]
        rec["client_protocol"] = want
        ci = params.get("clientInfo") if isinstance(params, dict) else None
        if isinstance(ci, dict):
            rec["client_info"] = {"name": ci.get("name"), "version": ci.get("version")}
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": ver,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": state.args.name, "version": "0.1.0"},
            "instructions": "Kaban board stub for spikes.",
        }}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": mid, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        name = params.get("name") if isinstance(params, dict) else None
        args = (params.get("arguments") or {}) if isinstance(params, dict) else {}
        rec["tool"] = name
        rec["tool_args"] = {k: (str(v)[:200]) for k, v in args.items()} if isinstance(args, dict) else str(args)[:200]
        if name == "report_progress":
            if not isinstance(args, dict) or not isinstance(args.get("text"), str):
                return {"jsonrpc": "2.0", "id": mid, "result": text_result("error: 'text' (string) is required", True)}
            return {"jsonrpc": "2.0", "id": mid, "result": text_result("ok: progress recorded")}
        if name == "complete_stage":
            if not isinstance(args, dict) or not isinstance(args.get("summary"), str):
                return {"jsonrpc": "2.0", "id": mid, "result": text_result("error: 'summary' (string) is required", True)}
            return {"jsonrpc": "2.0", "id": mid, "result": text_result(state.args.ack)}
        return rpc_error(mid, -32602, "Unknown tool: %s" % name)
    if method in ("resources/list", "prompts/list", "resources/templates/list"):
        key = {"resources/list": "resources", "prompts/list": "prompts",
               "resources/templates/list": "resourceTemplates"}[method]
        return {"jsonrpc": "2.0", "id": mid, "result": {key: []}}
    return rpc_error(mid, -32601, "Method not found: %s" % method)


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "KabanMCPStub/0.1"

        def log_message(self, fmt, *args):  # тишина в stderr
            pass

        def _base_rec(self):
            return {
                "http_method": self.command,
                "path": self.path,
                "auth": classify_auth(state, self.headers.get("Authorization")),
                "header_names": sorted(k.lower() for k in self.headers.keys()),
                "user_agent": (self.headers.get("User-Agent") or "")[:120],
                "session_header": "present" if self.headers.get("Mcp-Session-Id") else "absent",
                "protocol_header": self.headers.get("MCP-Protocol-Version"),
                "accept": (self.headers.get("Accept") or "")[:80],
            }

        def _send(self, status, body=None, ctype="application/json", extra=None):
            data = b""
            if body is not None:
                data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
            self.send_response(status)
            if data:
                self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if data:
                self.wfile.write(data)

        def _read_body(self):
            te = (self.headers.get("Transfer-Encoding") or "").lower()
            if "chunked" in te:
                chunks = []
                while True:
                    line = self.rfile.readline().strip()
                    size = int(line.split(b";")[0], 16) if line else 0
                    if size == 0:
                        self.rfile.readline()
                        break
                    chunks.append(self.rfile.read(size))
                    self.rfile.readline()
                return b"".join(chunks)
            n = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(n) if n > 0 else b""

        def _path_ok(self):
            return self.path.split("?", 1)[0].rstrip("/") == state.args.path.rstrip("/")

        def do_GET(self):
            rec = self._base_rec()
            if not self._path_ok():
                rec["status"] = 404
                state.log(rec)
                return self._send(404, {"error": "not found"})
            rec["status"] = 405
            state.log(rec)
            self._send(405, {"error": "SSE stream not offered"}, extra={"Allow": "POST, DELETE"})

        def do_DELETE(self):
            rec = self._base_rec()
            rec["status"] = 200 if self._path_ok() else 404
            state.log(rec)
            self._send(rec["status"])

        def do_POST(self):
            rec = self._base_rec()
            body = self._read_body()
            if not self._path_ok():
                rec["status"] = 404
                state.log(rec)
                return self._send(404, {"error": "not found"})
            if rec["auth"] not in ("match", "disabled"):
                rec["status"] = 401
                try:
                    m = json.loads(body.decode("utf-8") or "null")
                    msgs = m if isinstance(m, list) else [m]
                    rec["rpc_methods"] = [x.get("method") for x in msgs if isinstance(x, dict)]
                    for x in msgs:
                        if isinstance(x, dict) and x.get("method") == "tools/call":
                            rec["tool"] = (x.get("params") or {}).get("name")
                            rec["rejected_tool_call"] = True
                except Exception:
                    pass
                state.log(rec)
                return self._send(401, rpc_error(None, -32001, "Unauthorized"))
            try:
                payload = json.loads(body.decode("utf-8"))
            except Exception:
                rec["status"] = 400
                state.log(rec)
                return self._send(400, rpc_error(None, -32700, "Parse error"))
            batch = isinstance(payload, list)
            msgs = payload if batch else [payload]
            responses = []
            for m in msgs:
                r = handle_rpc(state, m, rec)
                if r is not None:
                    responses.append(r)
            extra = {}
            if "initialize" in (rec.get("rpc_methods") or []):
                sid = str(uuid.uuid4())
                state.sessions.add(sid)
                extra["Mcp-Session-Id"] = sid
            if not responses:
                rec["status"] = 202
                state.log(rec)
                return self._send(202, extra=extra)
            rec["status"] = 200
            state.log(rec)
            self._send(200, responses if batch else responses[0], extra=extra)

    return Handler


def main():
    ap = argparse.ArgumentParser(description="Kaban MCP stub (Streamable HTTP)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0, help="0 = случайный свободный порт")
    ap.add_argument("--port-file", help="записать сюда выбранный порт")
    ap.add_argument("--path", default="/mcp")
    ap.add_argument("--log", help="JSONL-лог запросов")
    ap.add_argument("--name", default="kaban-board-stub")
    ap.add_argument("--token-env", default="KABAN_RUN_TOKEN")
    ap.add_argument("--no-auth", action="store_true")
    ap.add_argument("--ack", default="KABAN-ACK-" + uuid.uuid4().hex[:8],
                    help="строка, которую возвращает complete_stage")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        print("mcp_stub: слушаем только loopback", file=sys.stderr)
        return 2
    state = State(args)
    srv = ThreadingHTTPServer((args.host, args.port), make_handler(state))
    srv.daemon_threads = True
    port = srv.server_address[1]
    if args.port_file:
        tmp = args.port_file + ".tmp"
        with open(tmp, "w") as f:
            f.write("%d\n" % port)
        os.rename(tmp, args.port_file)
    print("mcp_stub %s listening on http://%s:%d%s" % (args.name, args.host, port, args.path), file=sys.stderr)
    sys.stderr.flush()

    def stop(signum, frame):
        threading.Thread(target=srv.shutdown).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        srv.serve_forever(poll_interval=0.2)
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
