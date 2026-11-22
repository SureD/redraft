from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "hooks/receive.py"
spec = importlib.util.spec_from_file_location("redraft_hook", SCRIPT)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


class HookTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        (self.root / ".git").mkdir()
        (self.root / "scripts").mkdir()
        (self.root / "scripts/architecture.json").write_text("{}")
        self.db = self.root / ".build/agent-monitor.sqlite3"
        self.payload = dict(hook_event_name="SubagentStart", cwd=str(self.root / "scripts"),
                            session_id="parent", agent_id="child", turn_id="t1",
                            transcript_path="private-transcript", last_assistant_message="private-message")

    def create_db(self):
        self.db.parent.mkdir()
        with closing(sqlite3.connect(self.db)) as db:
            db.executescript("""
                CREATE TABLE runs (id TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE codex_sessions (session TEXT PRIMARY KEY, run TEXT);
                CREATE TABLE codex_signals (id INTEGER PRIMARY KEY, session TEXT, agent TEXT,
                    turn TEXT, kind TEXT, at TEXT, run TEXT, UNIQUE (session, agent, turn, kind));
                INSERT INTO runs VALUES ('feature', '{"status":"active"}');
                INSERT INTO codex_sessions VALUES ('parent', 'feature');
            """)

    def test_unenrolled_does_not_create_or_collect(self):
        self.assertEqual(hook.handle(self.payload), {})
        self.assertFalse(self.db.parent.exists())
        self.create_db()
        self.assertEqual(hook.handle(dict(self.payload, session_id="unrelated")), {})
        with closing(sqlite3.connect(self.db)) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM codex_signals").fetchone(), (0,))

    def test_stop_and_start_keep_only_lifecycle_fields(self):
        self.create_db()
        stopped = dict(self.payload, hook_event_name="SubagentStop")
        self.assertEqual(hook.handle(stopped), {})
        response = hook.handle(self.payload)
        self.assertEqual(response, hook.handle(self.payload))
        output = response["hookSpecificOutput"]
        self.assertEqual(output["hookEventName"], "SubagentStart")
        self.assertIn('"session_id": "parent"', output["additionalContext"])
        self.assertIn('"agent_id": "child"', output["additionalContext"])
        self.assertNotIn("private-message", json.dumps(response))
        with closing(sqlite3.connect(self.db)) as db:
            self.assertEqual(db.execute("SELECT kind, run FROM codex_signals ORDER BY id").fetchall(),
                             [("SubagentStop", "feature"), ("SubagentStart", "feature")])
            self.assertNotIn("private-", repr(db.execute("SELECT * FROM codex_signals").fetchall()))

    def test_late_signal_does_not_move_to_the_next_request(self):
        self.create_db()
        hook.handle(self.payload)
        with closing(sqlite3.connect(self.db)) as db:
            db.execute("INSERT INTO runs VALUES (?, ?)", ("next", '{"status":"active"}'))
            db.execute("UPDATE codex_sessions SET run='next'")
            db.commit()
        self.assertEqual(hook.handle(dict(self.payload, hook_event_name="SubagentStop")), {})
        self.assertIn("next", hook.handle(dict(self.payload, turn_id="t2"))["hookSpecificOutput"]["additionalContext"])
        with closing(sqlite3.connect(self.db)) as db:
            self.assertEqual(db.execute("SELECT run, kind FROM codex_signals ORDER BY id").fetchall(),
                             [("feature", "SubagentStart"), ("next", "SubagentStart")])

    def test_no_signal_after_acceptance(self):
        self.create_db()
        with closing(sqlite3.connect(self.db)) as db:
            db.execute("UPDATE runs SET value=?", ('{"status":"accepted"}',))
            db.commit()
        self.assertEqual(hook.handle(self.payload), {})
        with closing(sqlite3.connect(self.db)) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM codex_signals").fetchone(), (0,))


if __name__ == "__main__":
    unittest.main()
