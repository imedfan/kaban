#!/usr/bin/env python3
"""BE-22: free probes and at most two manually invoked Cursor model starts.

Work (including the isolated HOME and session state) stays outside Git. Only
redacted evidence is written to --evidence. No login or credential copying.
"""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
from types import SimpleNamespace

from lib import kspike
import mcp_stub_server as mcp

MODEL = "cursor-grok-4.6-medium"
MODEL_NAME = "Grok 4.6 Medium"
MIN_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
PROMPT = ("This is a disposable Kaban CLI research repository. Only work in this repository. "
          "Call the kaban-board MCP report_progress tool with text 'BE22 started'. "
          "Create hello.txt containing exactly 'hello kaban\\n', then run "
          "'printf shell-ok > shell.txt'. Finally call the kaban-board MCP complete_stage "
          "tool with summary 'BE22 complete'. Reply DONE. Do not inspect credentials "
          "or environment variables and do not use any other MCP servers.")


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


def environment(home):
    # A deliberate allowlist: no inherited API keys, endpoint overrides or IDE context.
    env = {k: os.environ[k] for k in ("USER", "LOGNAME", "LANG", "TMPDIR") if k in os.environ}
    return dict(env, HOME=str(home), PATH=MIN_PATH)


class Spike:
    def __init__(self, work):
        self.work = Path(work).resolve()
        self.state_path = self.work / "state.json"
        self.state = json.loads(self.state_path.read_text())
        self.evidence = Path(self.state["evidence"])
        self.repo = self.work / "clone"
        self.home = self.work / "run-home"
        self.token = secrets.token_urlsafe(32)

    def scrub(self, text):
        text = kspike.scrub_text(text, [("KABAN_RUN_TOKEN", self.token)])[0]
        for path, label in ((str(self.repo), "<CLONE>"), (str(self.home), "<RUN_HOME>"),
                            (str(self.work), "<WORK>"), (self.state["userHome"], "<USER_HOME>")):
            text = text.replace(path, label)
        return text

    def write(self, name, value):
        text = value if isinstance(value, str) else json.dumps(value, indent=2, ensure_ascii=False) + "\n"
        path = self.evidence / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.scrub(text))

    def env(self, home=None):
        temporary = self.work / "tmp"
        temporary.mkdir(exist_ok=True)
        return dict(environment(home or self.home), KABAN_RUN_TOKEN=self.token, TMPDIR=str(temporary) + "/")

    @contextmanager
    def server(self, prefix):
        log_path = self.evidence / (prefix + "/mcp.jsonl")
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("w") as log:
            lock = threading.Lock()

            def record(row):
                row["monotonic"] = time.monotonic()
                with lock:
                    log.write(self.scrub(json.dumps(row)) + "\n")
                    log.flush()

            state = SimpleNamespace(token=self.token, sessions=set(), log=record,
                                    args=SimpleNamespace(name="kaban-board", ack="BE22-ACK", path="/mcp"))
            server = mcp.ThreadingHTTPServer(("127.0.0.1", 0), mcp.make_handler(state))
            server.daemon_threads = True
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            config = {"mcpServers": {"kaban-board": {
                "url": "http://127.0.0.1:%d/mcp" % server.server_port,
                "headers": {"Authorization": "Bearer ${env:KABAN_RUN_TOKEN}"}}}}
            save(self.repo / ".cursor/mcp.json", config)
            self.write(prefix + "/mcp-config.json", config)
            try:
                yield
            finally:
                server.shutdown()
                thread.join()
                server.server_close()

    def free_command(self, prefix, args, home=None, status=False):
        result = subprocess.run([self.state["cli"], *args], cwd=self.repo, env=self.env(home),
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
        out = result.stdout.decode("utf-8", "replace")
        if status:
            # Account payload is intentionally never persisted, even redacted.
            try:
                raw = json.loads(out)
                out = json.dumps({k: raw[k] for k in ("isAuthenticated", "hasAccessToken", "hasRefreshToken")
                                  if k in raw and isinstance(raw[k], bool)}) + "\n"
            except (ValueError, TypeError):
                out = '{"unrecognizedStatus": true}\n'
        self.write(prefix + ".stdout", out)
        self.write(prefix + ".stderr", result.stderr.decode("utf-8", "replace"))
        self.write(prefix + ".exit", str(result.returncode) + "\n")
        return result.returncode, out

    def probes(self, prefix):
        with self.server(prefix):
            facts = {}
            for name, home in (("user-home", self.state["userHome"]), ("run-home", self.home)):
                rc, out = self.free_command(prefix + "/" + name + "/status",
                                            ["status", "--format", "json"], home, status=True)
                authenticated = rc == 0 and json.loads(out).get("isAuthenticated") is True
                rc, catalog = self.free_command(prefix + "/" + name + "/models", ["--list-models"], home)
                rows = kspike.parse_models(catalog)["rows"]
                model = rc == 0 and any(r["id"] == MODEL and r["name"] == MODEL_NAME for r in rows)
                self.free_command(prefix + "/" + name + "/mcp-list", ["mcp", "list"], home)
                facts[name] = {"authenticated": authenticated, "exactModelInCatalog": model}
            self.write(prefix + "/facts.json", facts)
            return facts


def prepare(args):
    work = Path(args.work).resolve()
    evidence = Path(args.evidence).resolve()
    # Never place an authenticated HOME under the versioned evidence directory.
    if evidence == work or evidence in work.parents or work in evidence.parents:
        raise ValueError("--work and --evidence must be separate directories")
    cli = shutil.which(args.cli)
    if not cli:
        raise ValueError("cursor-agent not found")
    work.mkdir(mode=0o700, parents=True, exist_ok=False)
    (work / "run-home").mkdir(mode=0o700)
    repo = work / "clone"
    repo.mkdir()
    git_env = dict(environment(work / "run-home"), GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
    subprocess.run(["/usr/bin/git", "init", "-q", str(repo)], env=git_env, check=True)
    (repo / "README.md").write_text("Disposable BE-22 repository. No product code or credentials.\n")
    subprocess.run(["/usr/bin/git", "-C", str(repo), "add", "README.md"], env=git_env, check=True)
    subprocess.run(["/usr/bin/git", "-C", str(repo), "-c", "user.name=Kaban Spike", "-c",
                    "user.email=spike@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"],
                   env=git_env, check=True)
    save(work / "state.json", {"cli": os.path.abspath(cli), "userHome": str(Path.home()),
                               "evidence": str(evidence), "starts": []})
    spike = Spike(work)
    for name, argv in (("version", ["--version"]), ("help", ["--help"])):
        spike.free_command("environment/" + name, argv)
    spike.write("environment/host.json", {"macOS": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
                                          if sys.platform == "darwin" else sys.platform,
                                          "modelId": MODEL, "modelName": MODEL_NAME, "modelStartsAtPreparation": 0})
    print("Prepared", work, "— no model started")


def launchd(spike):
    if sys.platform != "darwin":
        raise ValueError("launchd probe requires macOS")
    label = "app.kaban.spike.be22." + secrets.token_hex(4)
    plist = spike.work / "probe.plist"
    prefix = "launchd-keychain-home" if spike.state.get("keychainHomeLinked") else "launchd"
    done = spike.evidence / (prefix + "/facts.json")
    if done.exists():
        done.unlink()
    data = {"Label": label, "ProgramArguments": [sys.executable, str(Path(__file__).resolve()),
            "launchd-worker", "--work", str(spike.work)], "RunAtLoad": True,
            "EnvironmentVariables": environment(spike.state["userHome"]),
            "StandardOutPath": str(spike.work / "launchd.stdout"),
            "StandardErrorPath": str(spike.work / "launchd.stderr")}
    plist.write_bytes(plistlib.dumps(data))
    target = "gui/%d" % os.getuid()
    try:
        result = subprocess.run(["launchctl", "bootstrap", target, str(plist)], capture_output=True, timeout=15)
        spike.write(prefix + "/bootstrap.json", {"exit": result.returncode,
                    "stderr": result.stderr.decode("utf-8", "replace")})
        if result.returncode:
            raise ValueError("launchctl bootstrap failed; see launchd/bootstrap.json")
        deadline = time.monotonic() + 300
        while not done.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        if not done.exists():
            raise ValueError("launchd probe did not complete; see private launchd.stderr")
    finally:
        subprocess.run(["launchctl", "bootout", target + "/" + label], capture_output=True, timeout=15)


def keychain_home(spike):
    if spike.state["starts"]:
        raise ValueError("HOME setup is frozen after a model start")
    source = Path(spike.state["userHome"]) / "Library/Keychains"
    link = spike.home / "Library/Keychains"
    if not source.is_dir():
        raise ValueError("User Keychains directory not found")
    link.parent.mkdir(parents=True, exist_ok=True)
    if not link.is_symlink():
        # Refuse to replace any existing directory or credential store.
        link.symlink_to(source, target_is_directory=True)
    elif link.resolve() != source.resolve():
        raise ValueError("Unexpected Keychains symlink target")
    spike.state["keychainHomeLinked"] = True
    save(spike.state_path, spike.state)
    spike.write("environment/keychain-home.json", {
        "setup": "<RUN_HOME>/Library/Keychains -> <USER_HOME>/Library/Keychains",
        "credentialContentsCopied": False,
        "personalCursorConfigCopied": False,
        "scope": "Research workaround, not proof of credential isolation or a production decision"})


def claim_start(spike, kind):
    starts = spike.state["starts"]
    if len(starts) >= 2:
        raise ValueError("Both BE-22 model starts are already reserved; no automatic retry")
    if kind == "resume" and (not starts or not spike.state.get("sessionId")):
        raise ValueError("No captured session to resume")
    if kind == "resume" and not spike.state.get("firstComplete"):
        raise ValueError("First start failed; the second slot is reserved for explicit retry-first")
    if kind == "normal" and starts:
        raise ValueError("Use resume, or explicit retry-first for the remaining slot")
    if kind == "retry-first" and (len(starts) != 1 or spike.state.get("firstComplete")):
        raise ValueError("retry-first is only for a failed first start")
    starts.append({"kind": kind, "reservedAt": time.time()})
    # Reservation survives crash/spawn failure. Never refund or retry implicitly.
    save(spike.state_path, spike.state)
    return len(starts)


@contextmanager
def fs_trace(spike, prefix, pids):
    """Ask fs_usage to select the CLI PID, including all its threads, before exec."""
    if sys.platform != "darwin":
        raise ValueError("live filesystem observation requires macOS")
    monitor = subprocess.Popen(["sudo", "-n", "/usr/bin/fs_usage", "-w", "-f", "filesys", "-t", "300",
                                *[str(pid) for pid in sorted(pids)]],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    path = spike.evidence / (prefix + "/fs-usage.txt")
    errors = []

    def pump():
        with path.open("w") as out:
            for raw in monitor.stdout:
                line = raw.decode("utf-8", "replace")
                # The suffix in wide mode is a thread ID, NOT a process ID.
                # Filtering is performed by fs_usage itself using its PID argv.
                out.write(spike.scrub(line))
                out.flush()

    def stderr():
        for raw in monitor.stderr:
            errors.append(spike.scrub(raw.decode("utf-8", "replace")))

    threads = [threading.Thread(target=f, daemon=True) for f in (pump, stderr)]
    for thread in threads:
        thread.start()
    try:
        time.sleep(0.5)
        if monitor.poll() is not None:
            for thread in threads:
                thread.join(timeout=1)
            raise ValueError("fs_usage unavailable: " + "".join(errors).strip())
        yield
    finally:
        # Keep the controlling terminal for sudo's timestamp. Never signal its
        # process group: it is also the user's shell group. sudo forwards TERM.
        if monitor.poll() is None:
            monitor.terminate()
        try:
            monitor.wait(timeout=5)
        except subprocess.TimeoutExpired:
            monitor.kill()
            monitor.wait(timeout=5)
        for thread in threads:
            thread.join(timeout=5)
        monitor.stdout.close()
        monitor.stderr.close()
        spike.write(prefix + "/fs-usage-status.json", {"exit": monitor.returncode, "stderr": errors,
                    "coverage": "CLI leader PID (preserved across exec), all threads. "
                                "Subprocess filesystem operations are not traced. "
                                "Review write operations and paths manually. Not an exhaustive allowlist."})


@contextmanager
def metadata_trace(spike, prefix):
    """Stat only; never open auth/config/database contents or follow Keychains symlinks."""
    user_home = Path(spike.state["userHome"])
    roots = [spike.home, spike.repo, spike.work / "tmp", user_home / ".cursor",
             user_home / ".config/cursor", user_home / ".local/share/cursor-agent",
             user_home / "Library/Caches/cursor-compile-cache",
             user_home / "Library/Caches/cursor-agent",
             user_home / "Library/Logs/cursor-agent",
             user_home / "Library/Application Support/cursor-agent"]
    errors = []

    def snapshot():
        found = {}
        for root in roots:
            if not root.is_dir() or root.is_symlink():
                continue
            for directory, dirs, files in os.walk(root, followlinks=False,
                                                  onerror=lambda error: errors.append(str(error))):
                for name in dirs + files:
                    path = Path(directory) / name
                    try:
                        stat = path.lstat()
                        found[str(path)] = (stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)
                    except OSError as error:
                        errors.append(str(error))
                    if len(found) >= 100_000:
                        errors.append("100000 entry limit reached; snapshot incomplete")
                        return found
        return found

    before = snapshot()
    try:
        yield
    finally:
        after = snapshot()
        changes = [{"path": path, "change": "created" if path not in before else "removed"
                    if path not in after else "metadata_changed"}
                   for path in sorted(before.keys() | after.keys()) if before.get(path) != after.get(path)]
        spike.write(prefix + "/filesystem-changes.json", {
            "method": "lstat before/after; no file contents read",
            "roots": [str(root) for root in roots], "changes": changes, "errors": errors,
            "coverage": "Persistent metadata changes in listed roots only. No symlink traversal. "
                        "Transient files, writes outside roots, and Keychain writes are unobserved. "
                        "Other processes can change real-HOME roots; attribution requires review."})


def capture(spike, argv, prefix, kill_init, trace=False, timeout=240):
    folder = spike.evidence / prefix
    folder.mkdir(parents=True, exist_ok=True)
    # Gate exec until the filesystem observer is ready. The wrapper keeps its PID/PGID on exec.
    wrapper = "import os,sys; os.read(0,1); os.execve(sys.argv[1],sys.argv[1:],os.environ)"
    process = subprocess.Popen([sys.executable, "-c", wrapper, *argv], cwd=spike.repo, env=spike.env(),
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    pids = {process.pid}
    facts = {"initSeen": False, "toolsSeen": 0, "killRequested": False, "timedOut": False}
    started = time.monotonic()
    failures = []

    def output(stream, name):
        try:
            pump(stream, name)
        except Exception as error:
            failures.append(error)
            facts["killRequested"] = True

    def pump(stream, name):
        with (folder / name).open("w") as out, (folder / (name + ".times.jsonl")).open("w") as times:
            for raw in stream:
                line = raw.decode("utf-8", "replace")
                if name == "stream.jsonl":
                    try:
                        event = json.loads(line)
                    except ValueError:
                        event = {}
                    if not isinstance(event, dict):
                        event = {}
                    is_init = event.get("type") == "system" and event.get("subtype") == "init"
                    if event.get("type") == "tool_call":
                        facts["toolsSeen"] += 1
                    if is_init:
                        facts["initSeen"] = True
                        facts["sessionId"] = event.get("session_id")
                        facts["actualModel"] = event.get("model")
                    mismatch = is_init and event.get("model") not in (None, MODEL_NAME)
                    if mismatch or (kill_init and (is_init or event.get("type") == "tool_call")):
                        facts["killRequested"] = True
                        facts["killAtMs"] = round((time.monotonic() - started) * 1000)
                        try:
                            os.killpg(process.pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                out.write(spike.scrub(line))
                out.flush()
                times.write(json.dumps({"ms": round((time.monotonic() - started) * 1000),
                                        "kind": kspike.event_kind_of_line(line)}) + "\n")
                times.flush()

    threads = [threading.Thread(target=output, args=(process.stdout, "stream.jsonl"), daemon=True),
               threading.Thread(target=output, args=(process.stderr, "stderr.txt"), daemon=True)]
    from contextlib import nullcontext
    try:
        with metadata_trace(spike, prefix), (fs_trace(spike, prefix, pids) if trace else nullcontext()):
            for thread in threads:
                thread.start()
            process.stdin.write(b"1")
            process.stdin.close()
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                if time.monotonic() >= deadline or facts["killRequested"]:
                    facts["timedOut"] = time.monotonic() >= deadline
                    kspike.terminate_group(process.pid, grace=1, proc=process)
                    break
                time.sleep(0.02)
    finally:
        kspike.terminate_group(process.pid, grace=1, proc=process)
        process.wait(timeout=5)
        for thread in threads:
            if thread.ident:
                thread.join(timeout=5)
        for pipe in (process.stdin, process.stdout, process.stderr):
            if not pipe.closed:
                pipe.close()
        facts["exit"] = process.returncode
        facts["durationMs"] = round((time.monotonic() - started) * 1000)
        spike.write(prefix + "/process.json", facts)
    if failures:
        raise ValueError("Capture failed: " + str(failures[0]))
    spike.write(prefix + "/summary.json", kspike.sj_summary(str(folder / "stream.jsonl")))
    return facts


def paid(spike, kind):
    # Hold the lock across checks, reservation and execution, including in two terminals.
    with (spike.work / "paid.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        spike.state = json.loads(spike.state_path.read_text())
        if len(spike.state["starts"]) >= 2:
            raise ValueError("Two model starts already reserved")
        version_before = (spike.evidence / "environment/version.stdout").read_text()
        rc, version_now = spike.free_command("before-paid/version", ["--version"])
        if rc or version_now != version_before:
            raise ValueError("CLI version changed; repeat the free investigation before spending budget")
        rc, out = spike.free_command("before-paid/status", ["status", "--format", "json"], status=True)
        if rc or json.loads(out).get("isAuthenticated") is not True:
            raise ValueError("Isolated HOME is not authenticated. No model started")
        rc, catalog = spike.free_command("before-paid/models", ["--list-models"])
        if rc or not any(r["id"] == MODEL and r["name"] == MODEL_NAME for r in kspike.parse_models(catalog)["rows"]):
            raise ValueError("Exact authorized model not confirmed. No model started")
        number = len(spike.state["starts"]) + 1
        prefix = "run-%d" % number
        with spike.server(prefix):
            rc, listing = spike.free_command(prefix + "/mcp-list-before", ["mcp", "list"])
            if rc:
                raise ValueError("MCP preflight failed. No model started")
            print(spike.scrub(listing))
            print("Only kaban-board may be present; inspect", spike.evidence / prefix)
            if input("Type ONLY kaban-board to confirm the same-environment list: ") != "ONLY kaban-board":
                raise ValueError("MCP set not confirmed. No model started")
            argv = [spike.state["cli"], "-p", "--output-format", "stream-json", "--model", MODEL,
                    "--force", "--trust", "--approve-mcps"]
            if kind == "resume":
                argv += ["--resume", spike.state.get("sessionId", ""),
                         "Call report_progress with text 'BE22 resumed', then reply DONE."]
            else:
                argv += [PROMPT]
            claim_start(spike, kind)
            spike.write(prefix + "/argv.json", argv)
            result = capture(spike, argv, prefix, kill_init=kind == "resume")
        if result.get("sessionId"):
            spike.state["sessionId"] = result["sessionId"]
        if kind != "resume":
            spike.state["firstComplete"] = result["exit"] == 0 and result["initSeen"]
        save(spike.state_path, spike.state)
        print("Captured", prefix, "— reserved starts:", len(spike.state["starts"]), "/ 2")


def trace_test(spike, observer):
    sentinel = spike.repo / "be22-trace-check.txt"
    if sentinel.exists():
        sentinel.unlink()
    code = ("import time;from pathlib import Path;time.sleep(.2);"
            "Path('be22-trace-check.txt').write_text('trace check');time.sleep(.3);"
            "print('{\"type\":\"result\",\"result\":\"synthetic trace check\"}',flush=True)")
    result = capture(spike, [sys.executable, "-c", code], "trace-test", False,
                     trace=observer == "fs-usage", timeout=10)
    trace = (spike.evidence / ("trace-test/fs-usage.txt" if observer == "fs-usage" else
                              "trace-test/filesystem-changes.json")).read_text()
    if result["exit"] or "be22-trace-check.txt" not in trace:
        raise ValueError("Filesystem observer not verified. No model started; inspect trace-test/")
    print("Filesystem observer verified with synthetic Python process. No model started.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "free", "keychain-home", "launchd", "launchd-worker", "trace-test", "paid"])
    parser.add_argument("--work", required=True)
    parser.add_argument("--evidence")
    parser.add_argument("--cli", default="cursor-agent")
    parser.add_argument("--kind", choices=["normal", "resume", "retry-first"], default="normal")
    parser.add_argument("--observer", choices=["metadata", "fs-usage"], default="metadata",
                        help="trace-test only; paid always captures metadata deltas")
    args = parser.parse_args()
    # Ctrl-C/SIGTERM also tear down child process groups through finally blocks.
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    if args.command == "prepare":
        if not args.evidence:
            parser.error("prepare requires --evidence")
        prepare(args)
        return
    spike = Spike(args.work)
    if args.command in ("free", "launchd-worker"):
        prefix = "launchd" if args.command == "launchd-worker" else "free"
        if spike.state.get("keychainHomeLinked"):
            prefix += "-keychain-home"
        print(json.dumps(spike.probes(prefix), indent=2))
    elif args.command == "keychain-home":
        keychain_home(spike)
    elif args.command == "launchd":
        launchd(spike)
    elif args.command == "trace-test":
        trace_test(spike, args.observer)
    else:
        paid(spike, args.kind)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print("BE-22:", error, file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("BE-22 interrupted. Reserved paid starts are not refunded.", file=sys.stderr)
        sys.exit(130)
