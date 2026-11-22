#!/usr/bin/env python3
"""Local, read-only development dashboard and its event writer (Python 3.9+)."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
from urllib.parse import urlsplit
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DB = ROOT / ".build/agent-monitor.sqlite3"
TASK_STATES = ("queued", "working", "waiting", "decision", "verifying", "done", "failed", "unknown")
RUN_STATES = ("active", "verifying", "accepted", "failed")
HEARTBEAT_SECONDS = 5
STALE_SECONDS = 45


def now():
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def modules():
    nodes = json.loads((ROOT / "scripts/architecture.json").read_text())["nodes"]
    return [{"id": node["id"], "title": node["title"]} for node in nodes]


@contextmanager
def connection(path):
    db = sqlite3.connect(path, timeout=15, isolation_level=None)
    try:
        yield db
    finally:
        db.close()  # rolls back an incomplete transaction


def initialize(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with connection(path) as db:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY, run TEXT NOT NULL, value TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS run_events ON events (run, id DESC);
            CREATE TABLE IF NOT EXISTS codex_sessions (session TEXT PRIMARY KEY, run TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS codex_bindings (
                id INTEGER PRIMARY KEY, run TEXT NOT NULL, task TEXT NOT NULL,
                session TEXT NOT NULL, agent TEXT NOT NULL, at TEXT NOT NULL,
                UNIQUE(run, session, agent));
            CREATE TABLE IF NOT EXISTS codex_signals (
                id INTEGER PRIMARY KEY, session TEXT NOT NULL, agent TEXT NOT NULL,
                turn TEXT NOT NULL, kind TEXT NOT NULL, at TEXT NOT NULL, run TEXT NOT NULL,
                UNIQUE(session, agent, turn, kind));
            CREATE INDEX IF NOT EXISTS run_signals ON codex_signals (run, id DESC);
        """)


def encode(value):
    return json.dumps(value, ensure_ascii=False)


def event(task, source, status, summary, evidence=""):
    return dict(at=now(), task=task, source=source, status=status, summary=summary,
                evidence=evidence, waitingFor="", decision="", recommendation="")


@contextmanager
def write_transaction(path):
    with connection(path) as db:
        db.execute("BEGIN IMMEDIATE")
        yield db
        db.commit()


@contextmanager
def edit_run(db, run_id, create=False):
    row = db.execute("SELECT value FROM runs WHERE id=?", (run_id,)).fetchone()
    if create and row:
        raise ValueError("需求已经存在：" + run_id)
    if not create and not row:
        raise ValueError("找不到需求：" + run_id)
    run = json.loads(row[0]) if row else {"id": run_id, "tasks": []}
    events = []
    yield run, events
    for item in events:
        db.execute("INSERT INTO events(run, value) VALUES (?, ?)", (run_id, encode(item)))
        run["updatedAt"] = item["at"]
    db.execute("INSERT OR REPLACE INTO runs VALUES (?, ?)", (run_id, encode(run)))


@contextmanager
def change(path, run_id):
    """Serialize read/modify/write and commit the state together with its event."""
    with write_transaction(path) as db, edit_run(db, run_id) as (run, events):
        yield run, events


def new_run(args):
    with write_transaction(args.db) as db, edit_run(db, args.run_id, create=True) as (run, events):
        run.update(title=args.title, goal=args.goal, acceptance=args.acceptance,
                   status="active", summary="", evidence="")
        events.append(event("", "coordinator", "active", "已建需求"))
        if args.session_id:
            enroll_session(db, args.session_id, run, events)


def enroll_session(db, session_id, run, events):
    if run["status"] not in ("active", "verifying"):
        raise ValueError("请先将需求设为 active，再接入 Codex 会话。")
    previous = db.execute(
        "SELECT r.id, r.value FROM codex_sessions s JOIN runs r ON r.id=s.run WHERE s.session=?",
        (session_id,)).fetchone()
    if previous:
        if previous[0] == run["id"]:
            return
        if json.loads(previous[1])["status"] in ("active", "verifying"):
            raise ValueError("这个 Codex 会话已关联另一项进行中的需求：" + previous[0])
    db.execute("INSERT OR REPLACE INTO codex_sessions(session,run) VALUES (?,?)",
               (session_id, run["id"]))
    events.append(event("", "coordinator", run["status"], "已为本需求接入 Codex 子 Agent 通知"))


def enroll(args):
    with write_transaction(args.db) as db, edit_run(db, args.run_id) as (run, events):
        enroll_session(db, args.session_id, run, events)


def bind_agent(args):
    with write_transaction(args.db) as db, edit_run(db, args.run_id) as (run, events):
        registered = db.execute("SELECT 1 FROM codex_sessions WHERE session=? AND run=?",
                                (args.session_id, args.run_id)).fetchone()
        if not registered:
            raise ValueError("请先为此需求登记正确的父会话（enroll）。")
        task = get_task(run, args.task_id)
        key = (args.run_id, args.session_id, args.agent_id)
        bound = db.execute("SELECT task FROM codex_bindings WHERE run=? AND session=? AND agent=?",
                           key).fetchone()
        if bound:
            if bound[0] != args.task_id:
                raise ValueError("此子 Agent 在该需求中已负责任务：" + bound[0])
            return
        if run["status"] not in ("active", "verifying"):
            raise ValueError("请先将需求设为 active，再关联子 Agent。")
        item = event(args.task_id, "coordinator", task["status"], "已关联 Codex 子 Agent 身份")
        db.execute("INSERT INTO codex_bindings(run,session,agent,task,at) VALUES (?,?,?,?,?)",
                   (*key, args.task_id, item["at"]))
        events.append(item)


def editable(run):
    if run["status"] == "accepted":
        raise ValueError("需求已通过验收。继续修改前请先使用 review 将需求重新设为 active。")


def get_task(run, task_id):
    for task in run["tasks"]:
        if task["id"] == task_id:
            return task
    raise ValueError("找不到任务：" + task_id)


def new_task(args):
    if args.module and args.module not in {item["id"] for item in modules()}:
        raise ValueError("架构清单中没有模块：" + args.module)
    with change(args.db, args.run_id) as (run, events):
        editable(run)
        if any(task["id"] == args.task_id for task in run["tasks"]):
            raise ValueError("任务已经存在：" + args.task_id)
        item = event(args.task_id, "coordinator", "queued", args.summary)
        run["tasks"].append(dict(id=args.task_id, module=args.module, agent=args.agent,
                                 assignment=args.summary, summary=args.summary, status="queued",
                                 source="coordinator", updatedAt=item["at"], process=None,
                                 evidence="", waitingFor="", decision="", recommendation=""))
        events.append(item)


def update_task(task, item, waiting="", decision="", recommendation=""):
    task.update(status=item["status"], summary=item["summary"], source=item["source"],
                updatedAt=item["at"], evidence=item["evidence"], waitingFor=waiting,
                decision=decision, recommendation=recommendation)


def report(args):
    if args.status == "decision" and not args.decision:
        raise ValueError("请用 --decision 写出待定问题。")
    if args.status == "waiting" and not args.waiting_for:
        raise ValueError("请用 --waiting-for 写出等待对象或条件。")
    with change(args.db, args.run_id) as (run, events):
        editable(run)
        task = get_task(run, args.task_id)
        item = event(args.task_id, args.source, args.status, args.summary, args.evidence)
        item.update(waitingFor=args.waiting_for, decision=args.decision, recommendation=args.recommendation)
        update_task(task, item, args.waiting_for, args.decision, args.recommendation)
        events.append(item)


def fresh(process):
    if not process or process["status"] != "running":
        return False
    age = datetime.now(timezone.utc) - datetime.fromisoformat(process["lastSeen"])
    return age.total_seconds() <= STALE_SECONDS


def still_owned(process):
    """A stopped heartbeat does not prove that the command stopped executing."""
    if not process or process["status"] != "running":
        return False
    if fresh(process):
        return True
    for key, probe in (("wrapperPid", os.kill), ("groupId", os.killpg)):
        pid = process.get(key)
        if pid:
            try:
                probe(pid, 0)  # existence check only; never send a terminating signal
                return True
            except ProcessLookupError:
                continue
            except PermissionError:
                return True
    return False


def review(args):
    with change(args.db, args.run_id) as (run, events):
        if args.status == "accepted":
            if not args.evidence:
                raise ValueError("请用 --evidence 记录整体验收结果。")
            if any(t["status"] != "done" or still_owned(t["process"]) for t in run["tasks"]):
                raise ValueError("仍有任务未完成或有受监控进程正在运行。")
            for task in run["tasks"]:
                process = task["process"]
                if process and process["status"] == "running":
                    # Owner disappeared. Freeze its observation at the accepted
                    # baseline, even if a delayed handler later resurfaces.
                    process.update(status="unknown")
                    process.pop("token", None)
        run.update(status=args.status, summary=args.summary, evidence=args.evidence)
        events.append(event("", "coordinator", args.status, args.summary, args.evidence))


def start_process(args, token):
    with change(args.db, args.run_id) as (run, events):
        editable(run)
        task = get_task(run, args.task_id)
        if still_owned(task["process"]):
            process = task["process"]
            raise ValueError(f"上一次命令仍由监控器（PID {process.get('wrapperPid', '?')}）"
                             f"或进程组 {process.get('groupId', '?')} 占用。请等待原命令退出后重试。")
        item = event(task["id"], "process", "working", "已启动命令")
        # Hold the per-database transaction through spawn: a competing wrapper
        # cannot start the same task until this attempt has published its state.
        try:
            child = subprocess.Popen(args.command, start_new_session=True)
        except OSError as error:
            item = event(task["id"], "process", "failed", "启动失败：" + str(error))
            task["process"] = dict(status="failed", exitCode=None, lastSeen=item["at"])
            update_task(task, item)
            events.append(item)
            return None
        task["process"] = dict(status="running", token=token, exitCode=None, lastSeen=item["at"],
                               wrapperPid=os.getpid(), groupId=child.pid)
        update_task(task, item)
        events.append(item)
    return child


def refresh_process(args, token, code=None):
    with change(args.db, args.run_id) as (run, events):
        task = get_task(run, args.task_id)
        process = task["process"]
        if run["status"] == "accepted" or not process or process.get("token") != token:
            return  # a new attempt owns the task after an unobserved interval
        process["lastSeen"] = now()
        if code is None:
            return
        process.update(status="failed" if code else "exited", exitCode=code)
        process.pop("token", None)
        if code:
            item = event(task["id"], "process", "failed", f"命令异常退出（{code}）")
            update_task(task, item)
        else:
            item = event(task["id"], "process", "verifying", "命令正常退出，等待任务结果确认")
            if task["status"] in ("queued", "working", "unknown"):
                update_task(task, item)
            else:
                item = event(task["id"], "process", task["status"], "命令正常退出")
        events.append(item)


def wrap(args):
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        raise ValueError("请在 -- 后提供要运行的命令。")
    token = uuid4().hex
    child = None
    pending_signals = set()

    def forward(signum, _frame):
        if child is None:
            pending_signals.add(signum)
            return
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass

    signals = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    old_handlers = {sig: signal.signal(sig, forward) for sig in signals}
    try:
        child = start_process(args, token)
        if child is None:
            return 127
        for signum in pending_signals:
            forward(signum, None)
        while True:
            try:
                code = child.wait(timeout=HEARTBEAT_SECONDS)
                break
            except subprocess.TimeoutExpired:
                refresh_process(args, token)
        refresh_process(args, token, code)
        return code if code >= 0 else 128 - code
    finally:
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


def public_task(task):
    process = task["process"]
    if not process:
        return
    process.pop("token", None)
    if process["status"] == "running" and not fresh(process):
        process["status"] = "unknown"
        if task["source"] == "process" and task["status"] == "working":
            task.update(status="unknown", summary="进程监控已失去心跳，当前状态待确认")


def codex_observations(db, run):
    # A binding can be made after both hooks have arrived. Project the stored
    # observations when reading so binding and hook delivery can race safely.
    tasks = {task["id"]: task for task in run["tasks"]}
    for task in tasks.values():
        task["codex"] = None
    bindings = db.execute(
        "SELECT task,session,agent,at FROM codex_bindings WHERE run=? ORDER BY id", (run["id"],))
    for task_id, session, agent, bound_at in bindings:
        # Stop may be the first or only signal for a turn. A late Start must
        # never reverse its Stop, nor should old-turn retries hide a new turn.
        latest = db.execute("""
            SELECT turn, MAX(CASE WHEN kind='SubagentStart' THEN at END),
                         MAX(CASE WHEN kind='SubagentStop' THEN at END)
            FROM codex_signals WHERE run=? AND session=? AND agent=?
            GROUP BY turn ORDER BY MIN(id) DESC LIMIT 1
        """, (run["id"], session, agent)).fetchone()
        turn, started, stopped = latest or ("", None, None)
        tasks[task_id]["codex"] = dict(sessionId=session, agentId=agent, turnId=turn,
                                       status="stopped" if stopped else "started" if started else "bound",
                                       updatedAt=stopped or started or bound_at)
    # Keep the same bound on history as the existing dashboard. The individual
    # task observation above remains available after its event ages out.
    signals = db.execute("""
        SELECT b.task,s.session,s.agent,s.turn,s.kind,s.at FROM codex_signals s
        JOIN codex_bindings b ON b.run=s.run AND b.session=s.session AND b.agent=s.agent
        WHERE s.run=? ORDER BY s.id DESC LIMIT 100
    """, (run["id"],))
    history = []
    for task_id, session, agent, turn, kind, at in signals:
        is_start = kind == "SubagentStart"
        item = event(task_id, "codex", "started" if is_start else "stopped",
                     "Codex 已启动子 Agent" if is_start else "Codex 收到子 Agent 本轮停止通知")
        item.update(at=at, sessionId=session, agentId=agent, turnId=turn)
        history.append(item)
    return history


def snapshot(path):
    with connection(path) as db:
        db.execute("BEGIN")
        runs = []
        for (value,) in db.execute("SELECT value FROM runs"):
            run = json.loads(value)
            for task in run["tasks"]:
                public_task(task)
            rows = db.execute(
                "SELECT value FROM events WHERE run=? ORDER BY id DESC LIMIT 100", (run["id"],))
            history = [json.loads(row[0]) for row in rows] + codex_observations(db, run)
            run["events"] = sorted(history, key=lambda item: item["at"], reverse=True)[:100]
            run["updatedAt"] = max(run["updatedAt"], run["events"][0]["at"])
            runs.append(run)
    return {"modules": modules(), "runs": sorted(runs, key=lambda r: r["updatedAt"], reverse=True)}


class MonitorHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Host", "").split(":")[0] not in {"127.0.0.1", "localhost"}:
            self.send_error(403)
            return
        route = urlsplit(self.path).path
        try:
            if route == "/api/state":
                payload = encode(snapshot(self.server.store_path)).encode()
                mime = "application/json"
            elif route in ("/", "/architecture.html"):
                file = "scripts/agent_monitor.html" if route == "/" else "architecture.html"
                payload = (ROOT / file).read_bytes()
                mime = "text/html"
            else:
                self.send_error(404)
                return
        except (OSError, ValueError, sqlite3.Error) as error:
            self.log_error("reading dashboard: %s", error)
            self.send_error(503)
            return
        self.send_response(200)
        self.send_header("Content-Type", mime + "; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(payload)

    def log_request(self, code="-", size="-"):
        if isinstance(code, int) and code >= 400:
            super().log_request(code, size)


def serve(args):
    with ThreadingHTTPServer(("127.0.0.1", args.port), MonitorHandler) as server:
        server.store_path = args.db
        print(f"运行看板 http://127.0.0.1:{server.server_port}/", flush=True)
        server.serve_forever()


def required_text(value):
    if not value.strip():
        raise argparse.ArgumentTypeError("内容不能为空")
    return value


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--db", type=Path, default=DEFAULT_DB, help="本地记录文件")
    actions = cli.add_subparsers(dest="action", required=True)
    server = actions.add_parser("serve", help="打开本地只读服务")
    server.add_argument("--port", type=int, default=8765)

    new = actions.add_parser("new", help="登记需求和整体验收条件")
    attach = actions.add_parser("enroll", help="将父 Codex 会话接入已有需求")
    bind = actions.add_parser("bind", help="关联模块任务与真实 Codex 子 Agent 身份")
    task = actions.add_parser("task", help="分配模块任务")
    msg = actions.add_parser("report", help="记录任务进展、决策或结果")
    launch = actions.add_parser("run", help="运行命令并记录生命周期")
    outcome = actions.add_parser("review", help="更新需求状态及整体验收结果")
    for cmd in (new, attach, bind, task, msg, launch, outcome):
        cmd.add_argument("run_id", type=required_text)
    for cmd in (task, msg, launch, bind):
        cmd.add_argument("task_id", type=required_text)
    for cmd in (new, attach, bind):
        cmd.add_argument("--session-id", type=required_text, required=cmd is not new)
    bind.add_argument("--agent-id", required=True, type=required_text)
    for field in ("title", "goal", "acceptance"):
        new.add_argument("--" + field, required=True, type=required_text)
    task.add_argument("--module", default="")
    task.add_argument("--agent", required=True, type=required_text)
    for cmd in (task, msg, outcome):
        cmd.add_argument("--summary", required=True, type=required_text)
    msg.add_argument("status", choices=TASK_STATES)
    msg.add_argument("--source", choices=("agent", "coordinator"), default="agent")
    for field in ("waiting-for", "decision", "recommendation"):
        msg.add_argument("--" + field, default="")
    for cmd in (msg, outcome):
        cmd.add_argument("--evidence", default="")
    launch.add_argument("command", nargs=argparse.REMAINDER)
    outcome.add_argument("status", choices=RUN_STATES)
    return cli


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        initialize(args.db)
        if args.action == "serve":
            serve(args)
        elif args.action == "run":
            return wrap(args)
        else:
            {"new": new_run, "enroll": enroll, "bind": bind_agent, "task": new_task,
             "report": report, "review": review}[args.action](args)
        return 0
    except (ValueError, OSError, sqlite3.Error) as error:
        print(error, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
