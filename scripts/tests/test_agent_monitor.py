import contextlib
import io
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import agent_monitor as monitor

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "plugins/redraft-flow/hooks"))
from receive import record_signal


class MonitorTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.db = Path(temp.name) / "events.sqlite3"
        self.call("new", "r", "--title", "恢复草稿", "--goal", "重开", "--acceptance", "恢复正文")

    def call(self, *args, code=0):
        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            result = monitor.main(["--db", str(self.db), *args])
        self.assertEqual(result, code, error.getvalue())

    def task(self, id="disk"):
        self.call("task", "r", id, "--agent", "writer", "--module", "library", "--summary", "保存")

    def state(self):
        return monitor.snapshot(self.db)["runs"][0]

    def signal(self, kind, turn="turn-1", session="parent", agent="child"):
        return record_signal(self.db, session=session, agent=agent, turn=turn, kind=kind)

    def test_codex_lifecycle_is_independent_and_can_precede_binding(self):
        self.call("enroll", "r", "--session-id", "parent")
        self.task()
        self.call("report", "r", "disk", "decision", "--summary", "等待设计决定",
                  "--decision", "快照格式？", "--recommendation", "沿用现有格式")
        self.assertIsNone(self.signal("SubagentStart", session="unregistered"))
        self.assertEqual(self.signal("SubagentStop"), "r")
        self.assertEqual(self.signal("SubagentStart"), "r")
        self.assertIsNone(self.state()["tasks"][0]["codex"])
        self.call("bind", "r", "disk", "--session-id", "parent", "--agent-id", "child")
        self.call("bind", "r", "disk", "--session-id", "parent", "--agent-id", "child")
        self.signal("SubagentStop")
        run = self.state()
        task = run["tasks"][0]
        self.assertEqual(run["status"], "active")
        self.assertEqual((task["status"], task["decision"], task["codex"]["status"]),
                         ("decision", "快照格式？", "stopped"))
        self.assertEqual(len([e for e in run["events"] if e["source"] == "codex"]), 2)
        self.assertEqual(sum(e["summary"] == "已关联 Codex 子 Agent 身份" for e in run["events"]), 1)
        self.task("other")
        self.call("bind", "r", "other", "--session-id", "parent", "--agent-id", "child", code=1)
        self.call("review", "r", "accepted", "--summary", "结束", "--evidence", "进程停止", code=1)

    def test_codex_late_stop_does_not_replace_newer_turn(self):
        self.task()
        self.call("enroll", "r", "--session-id", "parent")
        self.call("bind", "r", "disk", "--session-id", "parent", "--agent-id", "child")
        self.assertEqual(self.state()["tasks"][0]["codex"]["status"], "bound")
        self.signal("SubagentStart", "old")
        self.signal("SubagentStart", "new")
        self.signal("SubagentStop", "old")
        observation = self.state()["tasks"][0]["codex"]
        self.assertEqual((observation["turnId"], observation["status"]), ("new", "started"))
        self.signal("SubagentStop", "new")
        self.assertEqual(self.state()["tasks"][0]["codex"]["status"], "stopped")
        self.signal("SubagentStop", "later-stop-only")
        self.assertEqual(self.state()["tasks"][0]["codex"]["turnId"], "later-stop-only")

    def test_codex_enrollment_is_atomic_and_runs_are_isolated(self):
        new = ["--title", "后续需求", "--goal", "隔离", "--acceptance", "检查事件归属"]
        self.call("enroll", "r", "--session-id", "parent")
        self.call("new", "next", *new, "--session-id", "parent", code=1)
        self.assertEqual(len(monitor.snapshot(self.db)["runs"]), 1)
        self.signal("SubagentStart")
        self.call("review", "r", "failed", "--summary", "结束本次需求")
        self.assertIsNone(self.signal("SubagentStop"))
        self.call("new", "next", *new, "--session-id", "parent")
        self.assertIsNone(self.signal("SubagentStop"))
        self.assertEqual(self.signal("SubagentStop", "new"), "next")
        self.call("task", "next", "module", "--agent", "worker", "--summary", "新的任务")
        self.call("bind", "next", "module", "--session-id", "parent", "--agent-id", "child")
        self.assertEqual([e["turnId"] for e in self.state()["events"] if e["source"] == "codex"], ["new"])

    def test_concurrent_codex_notifications_and_bindings(self):
        for parent in ("first", "second"):
            self.call("enroll", "r", "--session-id", parent)
            self.task(parent)
        def record(i):
            parent = ("first", "second")[i % 2]
            if i < 2:
                args = monitor.parser().parse_args(["--db", str(self.db), "bind", "r", parent,
                                                    "--session-id", parent, "--agent-id", "child"])
                monitor.bind_agent(args)
            else:
                self.signal("SubagentStop" if i % 4 < 2 else "SubagentStart", session=parent)
        with ThreadPoolExecutor(6) as writers:
            list(writers.map(record, range(24)))
        run = self.state()
        self.assertEqual(len([e for e in run["events"] if e["source"] == "codex"]), 4)
        for task in run["tasks"]:
            self.assertEqual((task["codex"]["sessionId"], task["codex"]["status"]),
                             (task["id"], "stopped"))

    def test_command_and_explicit_acceptance(self):
        self.task()
        self.call("run", "r", "disk", "--", sys.executable, "-c", "pass")
        run = self.state()
        self.assertEqual(run["status"], "active")
        task = run["tasks"][0]
        self.assertEqual((task["status"], task["source"]), ("verifying", "process"))
        self.assertEqual(task["process"]["exitCode"], 0)
        self.assertNotIn("token", task["process"])
        self.call("review", "r", "accepted", "--summary", "验收", "--evidence", "重开", code=1)
        self.call("report", "r", "disk", "done", "--summary", "磁盘验证通过", "--evidence", "验收记录")
        self.call("review", "r", "accepted", "--summary", "验收", code=1)
        self.call("review", "r", "accepted", "--summary", "验收", "--evidence", "重开通过")
        self.assertEqual(self.state()["evidence"], "重开通过")
        self.call("report", "r", "disk", "working", "--summary", "新写入", code=1)
        self.call("review", "r", "active", "--summary", "重新开始")

    def test_nonzero_exit_launch_failure_and_retry(self):
        self.task()
        self.call("run", "r", "disk", "--", sys.executable, "-c", "raise SystemExit(7)", code=7)
        self.assertEqual(self.state()["tasks"][0]["process"]["exitCode"], 7)
        self.call("run", "r", "disk", "--", str(self.db.parent / "missing"), code=127)
        self.assertEqual(self.state()["tasks"][0]["process"]["status"], "failed")
        self.call("run", "r", "disk", "--", sys.executable, "-c", "pass")
        self.assertEqual(self.state()["tasks"][0]["status"], "verifying")

    def test_interrupt_reaches_wrapped_command(self):
        self.task()
        command = [sys.executable, "-B", monitor.__file__, "--db", str(self.db), "run", "r",
                   "disk", "--", sys.executable, "-c", "import time; time.sleep(10)"]
        with subprocess.Popen(command) as launcher:
            deadline = time.monotonic() + 5
            while not self.state()["tasks"][0]["process"] and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertIsNotNone(self.state()["tasks"][0]["process"])
            launcher.send_signal(signal.SIGTERM)
            self.assertEqual(launcher.wait(timeout=3), 128 + signal.SIGTERM)
        task = self.state()["tasks"][0]
        self.assertEqual((task["status"], task["process"]["exitCode"]), ("failed", -signal.SIGTERM))

    def test_explicit_blockers_and_resolutions(self):
        self.task()
        self.call("report", "r", "disk", "decision", "--summary", "需要设计决定", code=1)
        self.call("report", "r", "disk", "decision", "--summary", "需要设计决定",
                  "--decision", "格式？", "--recommendation", "保留版本", "--source", "coordinator")
        t = self.state()["tasks"][0]
        self.assertEqual((t["decision"], t["recommendation"], t["source"]),
                         ("格式？", "保留版本", "coordinator"))
        self.call("report", "r", "disk", "waiting", "--summary", "等接口", "--waiting-for", "会话")
        t = self.state()["tasks"][0]
        self.assertEqual((t["decision"], t["waitingFor"]), ("", "会话"))
        self.call("report", "r", "disk", "working", "--summary", "已恢复")
        past = self.state()["events"]
        self.assertEqual(past[1]["waitingFor"], "会话")
        self.assertEqual((past[2]["decision"], past[2]["recommendation"]), ("格式？", "保留版本"))

    def test_competing_writers_preserve_events(self):
        def create(i):
            args = monitor.parser().parse_args(["--db", str(self.db), "task", "r", str(i),
                                               "--agent", "worker", "--summary", str(i)])
            monitor.new_task(args)
        with ThreadPoolExecutor(8) as writers:
            list(writers.map(create, range(16)))
        self.assertEqual(len(self.state()["tasks"]), 16)
        self.assertEqual(len(self.state()["events"]), 17)
        self.call("task", "r", "0", "--agent", "x", "--summary", "duplicate", code=1)
        self.assertEqual(len(self.state()["events"]), 17)

    def test_lost_wrapper_and_late_process_exit(self):
        self.task()
        args = monitor.parser().parse_args(["--db", str(self.db), "run", "r", "disk", "--", "unused"])
        with monitor.change(self.db, "r") as (run, _):
            task = run["tasks"][0]
            task.update(status="working", source="process",
                        process=dict(status="running", token="old", exitCode=None,
                                     lastSeen="2001-01-01T00:00:00+00:00"))
        self.assertEqual(self.state()["tasks"][0]["status"], "unknown")
        self.call("run", "r", "disk", "--", sys.executable, "-c", "pass")
        monitor.refresh_process(args, "old", 1)
        self.assertEqual(self.state()["tasks"][0]["process"]["exitCode"], 0)

    def test_stale_heartbeat_with_live_child_blocks_second_execution(self):
        self.task()
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"],
                                 start_new_session=True)
        try:
            with monitor.change(self.db, "r") as (run, _):
                run["tasks"][0].update(status="done", process=dict(status="running", token="old",
                                      exitCode=None, groupId=child.pid, lastSeen="2001-01-01T00:00:00+00:00"))
            self.call("run", "r", "disk", "--", sys.executable, "-c", "pass", code=1)
            self.call("review", "r", "accepted", "--summary", "结束", "--evidence", "证据", code=1)
        finally:
            child.terminate()
            child.wait(timeout=5)
        self.call("review", "r", "accepted", "--summary", "结束", "--evidence", "证据")
        args = monitor.parser().parse_args(["--db", str(self.db), "run", "r", "disk", "unused"])
        monitor.refresh_process(args, "old", 1)
        self.assertEqual(self.state()["tasks"][0]["status"], "done")
        self.assertEqual(self.state()["tasks"][0]["process"]["status"], "unknown")


if __name__ == "__main__":
    unittest.main()
