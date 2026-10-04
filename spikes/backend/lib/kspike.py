#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Вспомогательные утилиты спайков Kaban.

Только стандартная библиотека; совместимо с /usr/bin/python3 из Xcode CLT
(Python 3.9). Секреты не печатаются и не сохраняются: команды, которые трогают
Keychain или state.vscdb, выводят только факт наличия и имена атрибутов.

Подкоманды (python3 kspike.py <cmd> -h):
  run           запуск команды в своей группе процессов с таймаутом и захватом вывода
  killtest      запуск агента и SIGTERM всей группе после первого tool_call
  sj            сводка по stream-json (поля событий, модель, session_id, usage, tool_call)
  models        разбор вывода --list-models в JSON
  scrub         маскирование токенов/почты в каталоге с выводом (in place)
  grep-limits   поиск лимитных ошибок по всем файлам каталога
  keychain-scan имена атрибутов элементов Keychain, где встречается "cursor"
  login-state   эвристика "залогинен ли CLI" по выводу status
  sqlite-count  read-only count(*) ключа в state.vscdb (значение не читается)
  plist         сгенерировать plist временного LaunchAgent
  sblog         разбор строк нарушений Sandbox из `log show`
  suggest-write пути, куда писал CLI -> правила записи профиля (с защитой от HOME целиком)
  render-sb     подставить параметры в шаблон профиля Seatbelt
  mkfiles       сгенерировать N файлов (для тестового репозитория)
  stub-stats    статистика лога MCP-заглушки начиная со строки
  mcpjson       записать mcp.json (токен только как ${env:KABAN_RUN_TOKEN})
  mcp-check     сравнить вывод `mcp list` с ожидаемым набором серверов
  help-flags    вытащить список флагов из --help
  meta          прочитать поле из <prefix>.meta.json
  ms            текущее время в миллисекундах (epoch)
"""
from __future__ import print_function

import argparse
import datetime
import json
import os
import plistlib
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time

try:
    from urllib.parse import quote as urlquote
except ImportError:  # pragma: no cover
    from urllib import quote as urlquote  # type: ignore

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\r")
SECRET_NAME_RE = re.compile(r"(TOKEN|KEY|SECRET|PASSWORD|PASSWD|AUTH)", re.I)


def strip_ansi(s):
    return ANSI_RE.sub("", s)


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def write_text(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def write_json(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


def mask_argv(argv):
    """Маскирует значения секретов в argv (env VAR=..., --api-key X)."""
    out = []
    skip_next = False
    for a in argv:
        if skip_next:
            out.append("<redacted>")
            skip_next = False
            continue
        if a in ("--api-key",):
            out.append(a)
            skip_next = True
            continue
        if a.startswith("--api-key="):
            out.append("--api-key=<redacted>")
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", a)
        if m and SECRET_NAME_RE.search(m.group(1)):
            out.append(m.group(1) + "=<redacted>")
            continue
        out.append(a)
    return out


# ---------------------------------------------------------------- процессы

def ps_table():
    """[(pid, ppid, pgid, command)] для всех процессов (BSD и GNU ps)."""
    try:
        out = subprocess.check_output(
            ["ps", "-A", "-o", "pid=,ppid=,pgid=,stat=,command="],
            stderr=subprocess.DEVNULL).decode("utf-8", "replace")
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) < 4:
            continue
        try:
            pid, ppid, pgid = int(parts[0]), int(parts[1]), int(parts[2])
        except ValueError:
            continue
        if parts[3].startswith("Z"):
            continue  # зомби (ещё не прочитанный код выхода) — не живой процесс
        rows.append((pid, ppid, pgid, parts[4] if len(parts) > 4 else ""))
    return rows


def descendants(root):
    rows = ps_table()
    children = {}
    for pid, ppid, pgid, cmd in rows:
        children.setdefault(ppid, []).append((pid, ppid, pgid, cmd))
    res, stack = [], [root]
    while stack:
        cur = stack.pop()
        for row in children.get(cur, []):
            res.append(row)
            stack.append(row[0])
    return res


def group_members(pgid):
    me = os.getpid()
    return [r for r in ps_table() if r[2] == pgid and r[0] != me]


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def short_cmd(cmd, n=160):
    cmd = cmd.replace("\n", " ")
    return cmd if len(cmd) <= n else cmd[:n] + "…"


def event_kind_of_line(line):
    try:
        o = json.loads(line)
    except Exception:
        return "text"
    if not isinstance(o, dict):
        return "json"
    t = str(o.get("type", "?"))
    st = o.get("subtype")
    return t + ("/" + str(st) if st else "")


class Pump(object):
    """Читает stdout процесса построчно, пишет в файл и отмечает время строк."""

    def __init__(self, proc, fout, t0, times_path=None, on_line=None):
        self.proc, self.fout, self.t0 = proc, fout, t0
        self.times = open(times_path, "w", encoding="utf-8") if times_path else None
        self.on_line = on_line
        self.first_ms = None
        self.last_ms = None
        self.nlines = 0
        self.th = threading.Thread(target=self._run)
        self.th.daemon = True
        self.th.start()

    def _run(self):
        for raw in iter(self.proc.stdout.readline, b""):
            ms = int((time.monotonic() - self.t0) * 1000)
            if self.first_ms is None:
                self.first_ms = ms
            self.last_ms = ms
            self.nlines += 1
            self.fout.write(raw)
            self.fout.flush()
            line = raw.decode("utf-8", "replace").strip()
            if self.times:
                self.times.write(json.dumps({"ms": ms, "bytes": len(raw),
                                             "kind": event_kind_of_line(line)}) + "\n")
                self.times.flush()
            if self.on_line:
                try:
                    self.on_line(line, ms)
                except Exception:
                    pass
        if self.times:
            self.times.close()

    def join(self, timeout=5):
        self.th.join(timeout)


def terminate_group(pgid, grace=5.0, proc=None):
    """SIGTERM группе, через grace секунд SIGKILL. Возвращает список шагов.

    proc — Popen лидера группы: его надо «пожать» (poll), иначе он висит зомби.
    """
    steps = []
    try:
        os.killpg(pgid, signal.SIGTERM)
        steps.append("SIGTERM")
    except ProcessLookupError:
        return ["group-gone"]
    deadline = time.time() + grace
    while time.time() < deadline:
        if proc is not None:
            proc.poll()
        if not group_members(pgid):
            return steps
        time.sleep(0.2)
    try:
        os.killpg(pgid, signal.SIGKILL)
        steps.append("SIGKILL")
    except ProcessLookupError:
        pass
    return steps


class Interrupted(Exception):
    pass


def _raise_interrupted(signum, frame):
    raise Interrupted()


def install_interrupt_handlers():
    """SIGINT/SIGTERM/SIGHUP самому kspike -> исключение, чтобы убить группу ребёнка
    (ребёнок в своей сессии и Ctrl-C терминала не получает)."""
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(sig, _raise_interrupted)
        except (ValueError, OSError):
            pass


def norm_rc(rc):
    if rc is None:
        return 125
    return rc if rc >= 0 else 128 + (-rc)


def cmd_run(a):
    argv = list(a.cmd)
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv:
        print("run: пустая команда", file=sys.stderr)
        return 2
    prefix = a.out
    d = os.path.dirname(prefix)
    if d:
        os.makedirs(d, exist_ok=True)
    t0 = time.monotonic()
    started = now_iso()
    timed_out = False
    kill_steps = []
    with open(prefix + ".stdout", "wb") as fo, open(prefix + ".stderr", "wb") as fe:
        try:
            p = subprocess.Popen(argv, cwd=a.cwd or None, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=fe, start_new_session=True)
        except OSError as e:
            fe.write(("kspike run: не удалось запустить: %s\n" % e).encode())
            write_text(prefix + ".exit", "127\n")
            write_json(prefix + ".meta.json", {"argv": mask_argv(argv), "error": str(e), "exit": 127})
            return 127
        pump = Pump(p, fo, t0, prefix + ".times.jsonl" if a.line_times else None)
        install_interrupt_handlers()
        try:
            rc = p.wait(timeout=a.timeout)
        except Interrupted:
            terminate_group(p.pid, grace=3, proc=p)
            write_text(prefix + ".exit", "130\n")
            write_json(prefix + ".meta.json", {"argv": mask_argv(argv), "interrupted": True})
            return 130
        except subprocess.TimeoutExpired:
            timed_out = True
            kill_steps = terminate_group(p.pid, proc=p)
            try:
                rc = p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.kill(p.pid, signal.SIGKILL)
                rc = p.wait()
        pump.join()
    dur = int((time.monotonic() - t0) * 1000)
    leftovers = [{"pid": r[0], "cmd": short_cmd(r[3])} for r in group_members(p.pid)]
    for r in leftovers:
        try:
            os.kill(r["pid"], signal.SIGKILL)
        except Exception:
            pass
    code = 124 if timed_out else norm_rc(rc)
    write_text(prefix + ".exit", "%d\n" % code)
    write_text(prefix + ".secs", "%.1f\n" % (dur / 1000.0))
    write_json(prefix + ".meta.json", {
        "argv": mask_argv(argv), "cwd": os.path.abspath(a.cwd or os.getcwd()),
        "started": started, "duration_ms": dur, "exit": code, "raw_returncode": rc,
        "timed_out": timed_out, "timeout_s": a.timeout, "kill_steps": kill_steps,
        "stdout_lines": pump.nlines, "first_stdout_ms": pump.first_ms,
        "last_stdout_ms": pump.last_ms, "leftovers_in_group_killed": leftovers,
    })
    return code


def cmd_killtest(a):
    """Запуск, на первом tool_call/started — пауза delay, снимок дерева, SIGTERM группе."""
    argv = list(a.cmd)
    if argv and argv[0] == "--":
        argv = argv[1:]
    prefix = a.out
    os.makedirs(os.path.dirname(prefix) or ".", exist_ok=True)
    trigger = threading.Event()
    info = {"trigger_kind": None, "trigger_ms": None}

    def on_line(line, ms):
        if trigger.is_set():
            return
        try:
            o = json.loads(line)
        except Exception:
            return
        if isinstance(o, dict) and o.get("type") == "tool_call" and o.get("subtype") == "started":
            tc = o.get("tool_call") or {}
            info["trigger_kind"] = ",".join(sorted(tc.keys())) if isinstance(tc, dict) else "?"
            info["trigger_ms"] = ms
            trigger.set()

    t0 = time.monotonic()
    res = {"argv": mask_argv(argv), "started": now_iso()}
    with open(prefix + ".stdout", "wb") as fo, open(prefix + ".stderr", "wb") as fe:
        p = subprocess.Popen(argv, cwd=a.cwd or None, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=fe, start_new_session=True)
        pump = Pump(p, fo, t0, prefix + ".times.jsonl", on_line)
        install_interrupt_handlers()
        try:
            got = trigger.wait(timeout=a.timeout)
        except Interrupted:
            terminate_group(p.pid, grace=3, proc=p)
            for r in descendants(p.pid):
                try:
                    os.kill(r[0], signal.SIGKILL)
                except Exception:
                    pass
            return 130
        res["tool_call_seen"] = bool(got)
        res.update(info)
        if p.poll() is not None:
            res["exited_before_kill"] = True
        time.sleep(a.delay)
        tree = descendants(p.pid)
        res["tree_before_kill"] = [{"pid": r[0], "ppid": r[1], "pgid": r[2],
                                    "same_group": r[2] == p.pid, "cmd": short_cmd(r[3])}
                                   for r in tree]
        tk = time.monotonic()
        res["kill_steps"] = terminate_group(p.pid, grace=a.grace, proc=p)
        try:
            rc = p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.kill(p.pid, signal.SIGKILL)
            rc = p.wait()
        res["exit_after_ms"] = int((time.monotonic() - tk) * 1000)
        res["exit"] = norm_rc(rc)
        res["raw_returncode"] = rc
        pump.join()
    time.sleep(3)
    survivors = [r for r in tree if alive(r[0])]
    res["survivors_3s"] = [{"pid": r[0], "pgid": r[2], "cmd": short_cmd(r[3])} for r in survivors]
    if a.sentinel:
        time.sleep(max(0, a.wait_after))
        res["sentinel"] = a.sentinel
        res["sentinel_exists_after_wait"] = os.path.exists(a.sentinel)
        res["wait_after_s"] = a.wait_after
    killed = []
    for r in survivors:
        if alive(r[0]):
            try:
                os.kill(r[0], signal.SIGKILL)
                killed.append(r[0])
            except Exception:
                pass
    res["survivors_killed_at_end"] = killed
    res["duration_ms"] = int((time.monotonic() - t0) * 1000)
    write_json(prefix + ".meta.json", res)
    write_text(prefix + ".exit", "%d\n" % res["exit"])
    print(json.dumps({k: res.get(k) for k in ("tool_call_seen", "trigger_kind", "kill_steps", "exit",
                                               "exit_after_ms")}, ensure_ascii=False))
    print("survivors_3s=%d" % len(res["survivors_3s"]))
    if a.sentinel:
        print("sentinel_exists_after_wait=%s" % res["sentinel_exists_after_wait"])
    return 0


# ---------------------------------------------------------------- stream-json

def load_events(path):
    evs, bad, text_lines = [], 0, []
    try:
        f = open(path, encoding="utf-8", errors="replace")
    except IOError:
        return evs, bad, text_lines
    with f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            try:
                o = json.loads(s)
            except Exception:
                bad += 1
                if len(text_lines) < 20:
                    text_lines.append(s[:300])
                continue
            if isinstance(o, dict):
                evs.append(o)
    return evs, bad, text_lines


def key_paths(o, prefix="", depth=0, maxdepth=2, skip=("message", "tool_call", "result_text")):
    out = []
    if isinstance(o, dict):
        for k in sorted(o.keys()):
            p = prefix + "." + k if prefix else k
            out.append(p)
            v = o[k]
            if depth + 1 < maxdepth and isinstance(v, dict) and k not in skip:
                out.extend(key_paths(v, p, depth + 1, maxdepth, skip))
    return out


def kind_of(o):
    t = str(o.get("type", "?"))
    st = o.get("subtype")
    return t + ("/" + str(st) if st else "")


def numeric_only(o, depth=0):
    if isinstance(o, dict) and depth < 4:
        return {k: numeric_only(v, depth + 1) for k, v in o.items()
                if isinstance(v, (int, float, dict, bool)) or v is None}
    if isinstance(o, (int, float, bool)) or o is None:
        return o
    return "<non-numeric>"


def find_usage(o):
    """Ищет usage-подобные поля в событии result."""
    found = {}
    if not isinstance(o, dict):
        return found
    for k, v in o.items():
        lk = k.lower()
        if any(w in lk for w in ("usage", "token", "cost", "credit")):
            found[k] = numeric_only(v) if isinstance(v, dict) else (v if isinstance(v, (int, float, bool)) or v is None else "<str len=%d>" % len(str(v)))
    return found


def tool_info(o):
    tc = o.get("tool_call")
    if not isinstance(tc, dict) or not tc:
        return None
    kind = sorted(tc.keys())[0]
    body = tc.get(kind) if isinstance(tc.get(kind), dict) else {}
    info = {"kind": kind, "call_id": o.get("call_id"), "subtype": o.get("subtype")}
    args = body.get("args") if isinstance(body, dict) else None
    if kind == "function" and isinstance(body, dict):
        info["name"] = body.get("name")
    if isinstance(args, dict):
        info["args_keys"] = sorted(args.keys())
        for k in ("name", "toolName", "tool_name", "server", "serverName", "providerIdentifier", "command"):
            if k in args and isinstance(args[k], str):
                info["arg_" + k] = args[k][:300]
    r = body.get("result") if isinstance(body, dict) else None
    if isinstance(r, dict):
        info["result_keys"] = sorted(r.keys())
        for rk, rv in r.items():
            if isinstance(rv, dict):
                info["result_" + rk + "_keys"] = sorted(rv.keys())[:20]
                for fld in ("exitCode", "exit_code", "stdout", "stderr", "reason", "message", "error"):
                    if fld in rv:
                        val = rv[fld]
                        info["result_" + rk + "_" + fld] = val[:600] if isinstance(val, str) else val
    return info


def sj_summary(path):
    evs, bad, text_lines = load_events(path)
    kinds, fields = {}, {}
    init = res = None
    sids, tools, errors, assistant_texts = [], [], [], []
    for o in evs:
        k = kind_of(o)
        kinds[k] = kinds.get(k, 0) + 1
        fs = fields.setdefault(k, set())
        fs.update(key_paths(o, maxdepth=3 if o.get("type") == "result" else 2))
        sid = o.get("session_id")
        if sid and sid not in sids:
            sids.append(sid)
        if k == "system/init" and init is None:
            init = o
        if o.get("type") == "result":
            res = o
        if o.get("type") == "tool_call":
            ti = tool_info(o)
            if ti:
                tools.append(ti)
        if o.get("type") == "assistant":
            try:
                for c in o["message"]["content"]:
                    if c.get("type") == "text":
                        assistant_texts.append(c.get("text", "")[:500])
            except Exception:
                pass
        if o.get("type") in ("error",) or o.get("is_error") is True or "error" in o:
            errors.append({kk: (str(vv)[:400]) for kk, vv in o.items() if kk not in ("message",)})
    out = {
        "file": path, "events": len(evs), "bad_lines": bad, "non_json_lines": text_lines,
        "event_kinds": kinds,
        "field_names": {k: sorted(v) for k, v in fields.items()},
        "session_ids": sids,
        "init": None, "result": None,
        "tool_calls": {
            "started": sum(1 for t in tools if t.get("subtype") == "started"),
            "completed": sum(1 for t in tools if t.get("subtype") == "completed"),
            "kinds": sorted(set(t["kind"] for t in tools)),
            "details": tools[:60],
        },
        "assistant_texts": assistant_texts[:20],
        "errors": errors[:20],
    }
    if init is not None:
        out["init"] = {"fields": sorted(init.keys()),
                       "model": init.get("model"), "session_id": init.get("session_id"),
                       "apiKeySource": init.get("apiKeySource"),
                       "permissionMode": init.get("permissionMode"),
                       "extra": {k: (v if isinstance(v, (int, float, bool)) or v is None else str(v)[:300])
                                 for k, v in init.items()
                                 if k not in ("type", "subtype", "model", "session_id", "apiKeySource",
                                              "permissionMode", "cwd")}}
    if res is not None:
        rt = res.get("result")
        out["result"] = {"fields": sorted(res.keys()), "subtype": res.get("subtype"),
                         "is_error": res.get("is_error"), "session_id": res.get("session_id"),
                         "duration_ms": res.get("duration_ms"),
                         "duration_api_ms": res.get("duration_api_ms"),
                         "request_id_present": "request_id" in res,
                         "usage_like": find_usage(res),
                         "result_text": rt[:1000] if isinstance(rt, str) else rt}
    return out


def dotget(o, path):
    cur = o
    for part in path.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur


def cmd_sj(a):
    s = sj_summary(a.file)
    if a.save:
        write_json(a.save, s)
    if a.get:
        v = dotget(s, a.get)
        if v is None:
            print("")
        elif isinstance(v, (dict, list)):
            print(json.dumps(v, ensure_ascii=False))
        else:
            print(v)
        return 0
    if not a.save:
        print(json.dumps(s, ensure_ascii=False, indent=2))
    return 0


# ---------------------------------------------------------------- models

ROW_RE = re.compile(r"^\s*(?:[-*•>]\s+)?([A-Za-z0-9][A-Za-z0-9._:/@+\-]*)\s+[-–—]\s+(.+?)\s*$")
FLAG_RE = re.compile(r"\s*[\(\[]((?:current|default|selected|active)[^\)\]]*)[\)\]]\s*$", re.I)


def parse_models(text):
    rows, unparsed = [], []
    for raw in strip_ansi(text).splitlines():
        line = raw.rstrip()
        if not line.strip():
            continue
        m = ROW_RE.match(line)
        if not m:
            unparsed.append(line.strip()[:200])
            continue
        mid, name = m.group(1), m.group(2)
        flags = []
        while True:
            fm = FLAG_RE.search(name)
            if not fm:
                break
            flags.append(fm.group(1).strip())
            name = name[:fm.start()].rstrip()
        rows.append({"id": mid, "name": name, "flags": flags, "raw": line.strip()})
    return {"rows": rows, "unparsed": unparsed}


def cmd_models(a):
    with open(a.file, encoding="utf-8", errors="replace") as f:
        parsed = parse_models(f.read())
    if a.save:
        write_json(a.save, parsed)
    if a.find:
        hits = [r for r in parsed["rows"] if r["id"] == a.find]
        if not hits:
            return 1
        print(hits[0]["name"])
        return 0
    if a.count:
        print(len(parsed["rows"]))
        return 0
    if not a.save:
        print(json.dumps(parsed, ensure_ascii=False, indent=2))
    return 0


def cmd_name_match(a):
    """Сравнение отображаемого имени из init с именем каталога."""
    req, act = (a.catalog or "").strip(), (a.init or "").strip()
    if not act:
        print("no_init_model")
    elif not req:
        print("no_catalog_name")
    elif req == act:
        print("exact")
    elif req.casefold() == act.casefold():
        print("casefold")
    elif re.sub(r"[\s\-_.]", "", req).casefold() == re.sub(r"[\s\-_.]", "", act).casefold():
        print("normalized")
    else:
        print("different")
    return 0


# ---------------------------------------------------------------- scrub / grep

SCRUB_PATTERNS = [
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"), "<redacted:jwt>"),
    ("bearer", re.compile(r"(?i)(bearer\s+)(?!\$\{)([A-Za-z0-9._~+/=-]{12,})"), r"\1<redacted>"),
    ("apikey", re.compile(r"\b(?:key_|crsr_|sk-|sk_|user_)[A-Za-z0-9_-]{20,}"), "<redacted:key>"),
    ("url-secret", re.compile(r"(?i)([?&](?:api[_-]?key|access[_-]?token|token|key|secret|auth|sig|signature)=)[^&\s\"'<>]+"), r"\1<redacted>"),
    ("json-secret", re.compile(r"(?i)(\"(?:accessToken|refreshToken|access_token|refresh_token|apiKey|api_key|authorization|password|secret)\"\s*:\s*\")(?![^\"]*\$\{env:)([^\"]{6,})(\")"), r"\1<redacted>\3"),
    ("email", re.compile(r"(?<![\w.@-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b"), "<email>"),
]


def scrub_text(text, literals):
    counts = {}
    for name, val in literals:
        if val and val in text:
            counts["env:" + name] = text.count(val)
            text = text.replace(val, "<redacted:%s>" % name)
    for name, rx, rep in SCRUB_PATTERNS:
        text, n = rx.subn(rep, text)
        if n:
            counts[name] = counts.get(name, 0) + n
    return text, counts


def iter_files(root):
    for dp, dns, fns in os.walk(root):
        for fn in fns:
            yield os.path.join(dp, fn)


def cmd_scrub(a):
    literals = []
    for n in a.secret_env or []:
        v = os.environ.get(n)
        if v and len(v) >= 6:
            literals.append((n, v))
    total = {}
    changed = 0
    for p in iter_files(a.dir):
        if p.endswith((".zip", ".png", ".db", ".sqlite")):
            continue
        try:
            if os.path.getsize(p) > 50 * 1024 * 1024:
                continue
            with open(p, "rb") as f:
                data = f.read()
        except (IOError, OSError):
            continue
        if b"\x00" in data[:8192]:
            continue
        text = data.decode("utf-8", "replace")
        new, counts = scrub_text(text, literals)
        if counts:
            changed += 1
            for k, v in counts.items():
                total[k] = total.get(k, 0) + v
            with open(p, "w", encoding="utf-8") as f:
                f.write(new)
    print(json.dumps({"files_changed": changed, "replacements": total}, ensure_ascii=False))
    return 0


LIMIT_RE = re.compile(r"(?i)(usage[ _-]?limit|resource[_ ]exhausted|slow[ _-]?pool|spend[ _-]?limit|"
                      r"fallback[ _-]?model|rate[ _-]?limit|too many requests|quota|throttl|"
                      r"out of (?:fast )?requests|usage[- ]based|limit (?:reached|exceeded)|"
                      r"not available in the slow pool)")


def cmd_grep_limits(a):
    hits = []
    outp = os.path.abspath(a.outfile)
    skip_names = set(a.skip or [])
    for p in sorted(iter_files(a.dir)):
        if os.path.abspath(p) == outp or os.path.basename(p) in skip_names:
            continue
        bn = os.path.basename(p)
        if p.endswith((".zip", ".md", "summary.json", "meta.json", "times.jsonl", ".sb")) \
                or bn.startswith(("help", "models", "list-models", ".", "limit-hits")) or "/help" in p:
            continue
        rel = os.path.relpath(p, a.dir)
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                for i, line in enumerate(f, 1):
                    if LIMIT_RE.search(line):
                        hits.append("%s:%d: %s" % (rel, i, line.strip()[:400]))
        except (IOError, OSError):
            continue
    with open(a.outfile, "w", encoding="utf-8") as f:
        f.write("\n".join(hits) + ("\n" if hits else ""))
    print(len(hits))
    return 0


# ---------------------------------------------------------------- keychain

ATTR_RE = re.compile(r'^\s+(?:"([a-z0-9]{4})"|(0x[0-9A-Fa-f]{8}))\s*<[^>]*>=(.*)$')


def keychain_items(text):
    items, cur = [], None
    for line in text.splitlines():
        if line.startswith("keychain:"):
            if cur:
                items.append(cur)
            cur = {"keychain": line.split(":", 1)[1].strip().strip('"'), "attrs": [], "class": None}
            continue
        if cur is None:
            continue
        if line.startswith("class:"):
            cur["class"] = line.split(":", 1)[1].strip().strip('"')
            continue
        m = ATTR_RE.match(line)
        if m:
            cur["attrs"].append((m.group(1) or m.group(2), m.group(3).strip()))
    if cur:
        items.append(cur)
    return items


def cmd_keychain_scan(a):
    if a.service:
        argv = ["security", "find-generic-password", "-s", a.service]  # без -g/-w: секрет не читается
    else:
        argv = ["security", "dump-keychain"]  # без -d: только атрибуты
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=a.timeout)
        text = p.stdout.decode("utf-8", "replace")
        rc = p.returncode
    except subprocess.TimeoutExpired:
        print("timeout")
        return 1
    except OSError as e:
        print("error: %s" % e)
        return 1
    shown = 0
    for it in keychain_items(text):
        vals = " ".join(v for _, v in it["attrs"])
        if "cursor" not in vals.lower() and not a.service:
            continue
        shown += 1
        parts = ["class=%s" % it["class"], "keychain=%s" % os.path.basename(it["keychain"])]
        for name, val in it["attrs"]:
            if val in ("<NULL>", ""):
                continue
            if name in ("svce", "labl", "0x00000007", "desc", "srvr", "ptcl", "path"):
                parts.append("%s=%s" % (name, val[:120]))
            elif name == "acct":
                parts.append("acct=<есть, скрыто>")
        print("  " + "; ".join(parts))
    print("items_with_cursor=%d rc=%d" % (shown, rc))
    return 0


# ---------------------------------------------------------------- прочее

def cmd_login_state(a):
    text = ""
    for fn in a.files:
        try:
            with open(fn, encoding="utf-8", errors="replace") as f:
                text += f.read().lower() + "\n"
        except IOError:
            pass
    text = strip_ansi(text)
    neg = ["not logged in", "not authenticated", "unauthenticated", "please log in", "please login",
           "login required", "logged out", "no credentials", "not signed in", "sign in required",
           "authentication required", "run `agent login`", "run 'agent login'", "cursor-agent login"]
    pos = ["logged in", "authenticated", "signed in", "✓"]
    if any(n in text for n in neg):
        print("logged_out")
    elif any(p_ in text for p_ in pos):
        print("logged_in")
    else:
        print("unknown")
    return 0


def cmd_sqlite_count(a):
    if not os.path.exists(a.db):
        print("absent")
        return 0
    for mode in ("mode=ro", "mode=ro&immutable=1"):
        try:
            con = sqlite3.connect("file:%s?%s" % (urlquote(a.db), mode), uri=True, timeout=5)
            try:
                n = con.execute("SELECT count(*) FROM ItemTable WHERE key = ?", (a.key,)).fetchone()[0]
            finally:
                con.close()
            print("count=%d %s" % (n, mode))
            return 0
        except sqlite3.Error as e:
            last = "%s: %s" % (type(e).__name__, str(e)[:200])
    print("error=%s" % last)
    return 0


def cmd_plist(a):
    d = {"Label": a.label, "ProgramArguments": a.args, "RunAtLoad": True,
         "StandardOutPath": a.stdout, "StandardErrorPath": a.stderr,
         "WorkingDirectory": a.workdir, "ProcessType": "Interactive"}
    with open(a.out, "wb") as f:
        plistlib.dump(d, f)
    return 0


SB_LINE_RE = re.compile(r"Sandbox:\s+(.+?)\((\d+)\)\s+(?:System Policy:\s+)?deny\(\d+\)\s+(\S+)(?:\s+(.*))?$")


NEVER_ALLOW_REL = {"", "Library", "Library/Application Support", "Library/Caches", "Library/Preferences",
                   "Library/Logs", ".config", ".local", ".local/share", ".ssh", ".gnupg", "Documents",
                   "Desktop", "Downloads", ".gitconfig", ".cursor/mcp.json"}


def sb_regex_escape(p):
    return re.sub(r"([.^$*+?()\[\]{}|\\])", r"\\\1", p)


def suggest_write_paths(paths, home):
    """Пути, куда CLI писал (или где получил отказ), -> правила записи для профиля.

    Каталоги приложений: ~/.cursor/<x>, ~/.config/<app>, ~/.local/share/<app>,
    ~/Library/<Caches|Application Support|Logs|...>/<app>. Файл прямо в таком
    контейнере -> regex на файл и его временные варианты (атомарная запись).
    Никогда не предлагаем HOME, ~/Library, ~/.ssh, ~/.gitconfig и т. п. целиком.
    """
    home = os.path.realpath(home) if home else None
    out, skipped = set(), set()
    for t in paths:
        t = t.strip()
        if not t.startswith("/"):
            continue
        if home and (t == home or t.startswith(home + "/")):
            rel = t[len(home) + 1:] if t != home else ""
            parts = [x for x in rel.split("/") if x]
            if not parts:
                skipped.add(t)
                continue
            top = parts[0]
            if top == "Library":
                depth = 3
            elif top == ".local":
                depth = 3
            else:
                depth = 2
            if len(parts) == 1:
                cand = "regex:^" + sb_regex_escape(t) + "([.~-][^/]*)?$"
            elif len(parts) > depth:
                cand = home + "/" + "/".join(parts[:depth])
            else:
                cand = "regex:^" + sb_regex_escape(t) + "([.~-][^/]*)?$"
            crel = cand[len(home) + 1:] if cand.startswith(home + "/") else None
            if crel is not None and (crel in NEVER_ALLOW_REL or crel.startswith(".ssh")):
                skipped.add(t)
                continue
            if any(x in t for x in ("/.ssh/", "/.gitconfig", "/Cursor/User/globalStorage")):
                skipped.add(t)
                continue
            out.add(cand)
        else:
            d = os.path.dirname(t)
            if d in ("/", "/private", "/Users", "/private/var", "/usr", "/System", "/Library"):
                skipped.add(t)
                continue
            out.add(d)
    return sorted(out), sorted(skipped)


def cmd_suggest_write(a):
    with open(a.file, encoding="utf-8", errors="replace") as f:
        paths = [l.strip() for l in f if l.strip()]
    if a.exclude:
        paths = [p_ for p_ in paths if not any(p_.startswith(x) for x in a.exclude)]
    allow, skipped = suggest_write_paths(paths, a.home)
    for x in allow:
        print(x)
    if a.skipped_out:
        write_text(a.skipped_out, "\n".join(skipped) + ("\n" if skipped else ""))
    return 0


def proc_match(proc, pats):
    """Имя процесса из журнала Sandbox против списка: точное имя или префикс с '*'."""
    for p_ in pats:
        if p_.endswith("*"):
            if proc.startswith(p_[:-1]):
                return True
        elif proc == p_:
            return True
    return False


def cmd_sblog(a):
    seen, rows = set(), []
    with open(a.file, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = SB_LINE_RE.search(line.strip())
            if not m:
                continue
            proc, pid, op, target = m.group(1), m.group(2), m.group(3), (m.group(4) or "").strip()
            if a.procs and not proc_match(proc, a.procs):
                continue
            key = (proc, op, target)
            if key in seen:
                continue
            seen.add(key)
            rows.append({"proc": proc, "op": op, "target": target})
    targets = [r["target"] for r in rows if r["op"].startswith("file-write") and r["target"].startswith("/")]
    if a.exclude:
        targets = [t for t in targets if not any(t.startswith(x) for x in a.exclude)]
    suggest, _ = suggest_write_paths(targets, a.home)
    out = {"denials": rows, "suggested_write_paths": suggest}
    if a.save:
        write_json(a.save, out)
    if a.suggest:
        for s in sorted(suggest):
            print(s)
    else:
        print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


def sb_quote(p):
    return '"' + p.replace("\\", "\\\\").replace('"', '\\"') + '"'


def cmd_render_sb(a):
    with open(a.template, encoding="utf-8") as f:
        t = f.read()
    for kv in a.set or []:
        k, v = kv.split("=", 1)
        t = t.replace("@@%s@@" % k, v.replace("\\", "\\\\").replace('"', '\\"'))

    def lines(paths):
        out = []
        for p in paths or []:
            if not p:
                continue
            if p.startswith("literal:"):
                out.append("  (literal %s)" % sb_quote(p[len("literal:"):]))
            elif p.startswith("regex:"):
                out.append('  (regex #"%s")' % p[len("regex:"):].replace('"', '\\"'))
            else:
                out.append("  (subpath %s)" % sb_quote(p.rstrip("/") or "/"))
        return "\n".join(out) if out else "  ; (нет)"

    t = t.replace("@@EXTRA_WRITE@@", lines(a.write_path))
    t = t.replace("@@EXTRA_DENY_READ@@", lines(a.deny_read))
    t = t.replace("@@EXTRA_DENY_WRITE@@", lines(a.deny_write))
    left = re.findall(r"@@[A-Z_]+@@", t)
    if left:
        print("render-sb: не подставлены параметры: %s" % ", ".join(sorted(set(left))), file=sys.stderr)
        return 2
    write_text(a.out, t)
    return 0


def cmd_mkfiles(a):
    import random
    rnd = random.Random(a.seed)
    words = ["kaban", "stage", "task", "board", "agent", "merge", "clone", "gate", "review", "model",
             "quota", "seatbelt", "branch", "commit", "fetch", "warm", "path", "cache", "build", "run"]
    per_dir = 100
    for i in range(a.n):
        d = os.path.join(a.dir, a.prefix, "d%03d" % (i // per_dir))
        if i % per_dir == 0:
            os.makedirs(d, exist_ok=True)
        size = rnd.randint(a.min_size, a.max_size)
        buf = []
        n = 0
        while n < size:
            w = rnd.choice(words)
            buf.append(w)
            n += len(w) + 1
        with open(os.path.join(d, "f%05d.%s" % (i, a.ext)), "w") as f:
            f.write(" ".join(buf) + "\n")
    return 0


def cmd_stub_stats(a):
    st = {"requests": 0, "http": {}, "rpc": {}, "tools_called": [], "auth": {}, "user_agents": [],
          "statuses": {}, "paths": {}}
    try:
        f = open(a.log, encoding="utf-8", errors="replace")
    except IOError:
        print(json.dumps(st))
        return 0
    with f:
        for i, line in enumerate(f, 1):
            if i <= a.from_line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            st["requests"] += 1
            for key, val in (("http", o.get("http_method")), ("auth", o.get("auth")),
                             ("statuses", str(o.get("status"))), ("paths", o.get("path"))):
                st[key][val] = st[key].get(val, 0) + 1
            for m in o.get("rpc_methods") or []:
                st["rpc"][m] = st["rpc"].get(m, 0) + 1
            if o.get("tool"):
                st["tools_called"].append({"tool": o["tool"], "auth": o.get("auth"),
                                           "args": o.get("tool_args")})
            ua = o.get("user_agent")
            if ua and ua not in st["user_agents"]:
                st["user_agents"].append(ua)
    if a.get:
        v = dotget(st, a.get)
        print("" if v is None else (json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v))
    else:
        print(json.dumps(st, ensure_ascii=False, sort_keys=True))
    return 0


def cmd_mcpjson(a):
    servers = {}
    for spec in a.server:
        name, rest = spec.split("=", 1)
        url, _, flags = rest.partition(",")
        entry = {"url": url}
        if "auth" in flags.split(","):
            entry["headers"] = {"Authorization": "Bearer ${env:%s}" % a.token_env}
        servers[name] = entry
    d = os.path.dirname(a.out)
    if d:
        os.makedirs(d, exist_ok=True)
    write_json(a.out, {"mcpServers": servers})
    return 0


def cmd_mcp_check(a):
    try:
        with open(a.file, encoding="utf-8", errors="replace") as f:
            text = strip_ansi(f.read())
    except IOError:
        text = ""
    expected = [e for e in (a.expect or "").split(",") if e]
    absent = [e for e in (a.absent or "").split(",") if e]

    def has(name):
        return re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(name), text) is not None

    lines = [l.strip() for l in text.splitlines() if l.strip()]
    other = [l[:200] for l in lines if not any(has_in(l, e) for e in expected + absent)]
    res = {"found": [e for e in expected if has(e)], "missing": [e for e in expected if not has(e)],
           "absent_ok": [e for e in absent if not has(e)], "absent_violated": [e for e in absent if has(e)],
           "other_lines": other[:40], "total_lines": len(lines)}
    print(json.dumps(res, ensure_ascii=False))
    return 0


def has_in(line, name):
    return re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(name), line) is not None


def cmd_help_flags(a):
    with open(a.file, encoding="utf-8", errors="replace") as f:
        text = strip_ansi(f.read())
    flags = sorted(set(re.findall(r"(?<![\w-])(--[a-z][a-z0-9-]*)", text)))
    if a.has:
        return 0 if a.has in flags else 1
    print("\n".join(flags))
    return 0


def cmd_meta(a):
    try:
        with open(a.prefix + ".meta.json", encoding="utf-8") as f:
            o = json.load(f)
    except (IOError, ValueError):
        print("")
        return 0
    v = dotget(o, a.key)
    print("" if v is None else (json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v))
    return 0


def cmd_ms(a):
    print(int(time.time() * 1000))
    return 0


def main():
    ap = argparse.ArgumentParser(description="Утилиты спайков Kaban")
    sp = ap.add_subparsers(dest="cmd_name")

    p = sp.add_parser("run")
    p.add_argument("--timeout", type=float, default=240)
    p.add_argument("--out", required=True)
    p.add_argument("--cwd")
    p.add_argument("--line-times", action="store_true")
    p.add_argument("cmd", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_run)

    p = sp.add_parser("killtest")
    p.add_argument("--timeout", type=float, default=180)
    p.add_argument("--delay", type=float, default=1.5)
    p.add_argument("--grace", type=float, default=5.0)
    p.add_argument("--out", required=True)
    p.add_argument("--cwd")
    p.add_argument("--sentinel")
    p.add_argument("--wait-after", type=float, default=30)
    p.add_argument("cmd", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_killtest)

    p = sp.add_parser("sj")
    p.add_argument("file")
    p.add_argument("--get")
    p.add_argument("--save")
    p.set_defaults(fn=cmd_sj)

    p = sp.add_parser("models")
    p.add_argument("file")
    p.add_argument("--save")
    p.add_argument("--find")
    p.add_argument("--count", action="store_true")
    p.set_defaults(fn=cmd_models)

    p = sp.add_parser("name-match")
    p.add_argument("--catalog", default="")
    p.add_argument("--init", default="")
    p.set_defaults(fn=cmd_name_match)

    p = sp.add_parser("scrub")
    p.add_argument("dir")
    p.add_argument("--secret-env", action="append")
    p.set_defaults(fn=cmd_scrub)

    p = sp.add_parser("grep-limits")
    p.add_argument("dir")
    p.add_argument("outfile")
    p.add_argument("--skip", action="append")
    p.set_defaults(fn=cmd_grep_limits)

    p = sp.add_parser("keychain-scan")
    p.add_argument("--service")
    p.add_argument("--timeout", type=float, default=60)
    p.set_defaults(fn=cmd_keychain_scan)

    p = sp.add_parser("login-state")
    p.add_argument("files", nargs="+")
    p.set_defaults(fn=cmd_login_state)

    p = sp.add_parser("sqlite-count")
    p.add_argument("db")
    p.add_argument("key")
    p.set_defaults(fn=cmd_sqlite_count)

    p = sp.add_parser("plist")
    p.add_argument("--out", required=True)
    p.add_argument("--label", required=True)
    p.add_argument("--stdout", required=True)
    p.add_argument("--stderr", required=True)
    p.add_argument("--workdir", required=True)
    p.add_argument("args", nargs="+")
    p.set_defaults(fn=cmd_plist)

    p = sp.add_parser("sblog")
    p.add_argument("file")
    p.add_argument("--home")
    p.add_argument("--procs", nargs="*")
    p.add_argument("--save")
    p.add_argument("--suggest", action="store_true")
    p.add_argument("--exclude", action="append", help="префиксы путей, отказы по которым ожидаемы")
    p.set_defaults(fn=cmd_sblog)

    p = sp.add_parser("suggest-write")
    p.add_argument("file", help="файл со списком путей, по одному в строке")
    p.add_argument("--home", required=True)
    p.add_argument("--exclude", action="append")
    p.add_argument("--skipped-out")
    p.set_defaults(fn=cmd_suggest_write)

    p = sp.add_parser("render-sb")
    p.add_argument("template")
    p.add_argument("out")
    p.add_argument("--set", action="append")
    p.add_argument("--write-path", action="append")
    p.add_argument("--deny-read", action="append")
    p.add_argument("--deny-write", action="append")
    p.set_defaults(fn=cmd_render_sb)

    p = sp.add_parser("mkfiles")
    p.add_argument("dir")
    p.add_argument("n", type=int)
    p.add_argument("--prefix", default="src")
    p.add_argument("--ext", default="txt")
    p.add_argument("--min-size", type=int, default=500)
    p.add_argument("--max-size", type=int, default=3000)
    p.add_argument("--seed", type=int, default=42)
    p.set_defaults(fn=cmd_mkfiles)

    p = sp.add_parser("stub-stats")
    p.add_argument("log")
    p.add_argument("--from-line", type=int, default=0)
    p.add_argument("--get")
    p.set_defaults(fn=cmd_stub_stats)

    p = sp.add_parser("mcpjson")
    p.add_argument("--out", required=True)
    p.add_argument("--token-env", default="KABAN_RUN_TOKEN")
    p.add_argument("--server", action="append", required=True, help="name=url[,auth]")
    p.set_defaults(fn=cmd_mcpjson)

    p = sp.add_parser("mcp-check")
    p.add_argument("file")
    p.add_argument("--expect", default="")
    p.add_argument("--absent", default="")
    p.set_defaults(fn=cmd_mcp_check)

    p = sp.add_parser("help-flags")
    p.add_argument("file")
    p.add_argument("--has")
    p.set_defaults(fn=cmd_help_flags)

    p = sp.add_parser("meta")
    p.add_argument("prefix")
    p.add_argument("key")
    p.set_defaults(fn=cmd_meta)

    p = sp.add_parser("ms")
    p.set_defaults(fn=cmd_ms)

    a = ap.parse_args()
    if not getattr(a, "fn", None):
        ap.print_help()
        return 2
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
