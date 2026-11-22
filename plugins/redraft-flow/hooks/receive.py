"""Record Codex lifecycle facts for an enrolled Redraft development request."""

from contextlib import closing
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
import subprocess
import sys


KINDS = {"SubagentStart", "SubagentStop"}


def workspace_stores(cwd):
    """Try the nearest checkout, then its main checkout for a linked worktree."""
    path = Path(cwd)
    if not path.is_absolute() or not path.is_dir():
        return
    path = path.resolve()
    for root in (path, *path.parents):
        git = root / ".git"
        if not git.exists():
            continue
        if not (root / "scripts/architecture.json").is_file():
            return
        yield root / ".build/agent-monitor.sqlite3"
        if git.is_file():
            common = subprocess.run(
                ["git", "-C", str(root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                capture_output=True, text=True, timeout=2, check=False,
            )
            git_dir = Path(common.stdout.strip())
            if common.returncode == 0 and git_dir.is_absolute() and git_dir.name == ".git":
                yield git_dir.parent / ".build/agent-monitor.sqlite3"
        return


def record_signal(db_path, *, session, agent, turn, kind):
    """Return the active run for this signal. Opening a hook never creates a DB."""
    path = Path(db_path)
    if kind not in KINDS or not path.is_file():
        return None
    lookup = """
        SELECT s.run, r.value FROM codex_sessions AS s JOIN runs AS r ON r.id = s.run
        WHERE s.session = ?
    """
    with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=rw", uri=True,
                                 timeout=1, isolation_level=None)) as db:
        db.execute("PRAGMA trusted_schema = OFF")
        if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='codex_sessions'").fetchone():
            return None
        if not db.execute(lookup, (session,)).fetchone():
            return None
        db.execute("BEGIN IMMEDIATE")
        row = db.execute(lookup, (session,)).fetchone()
        if not row:
            return None
        run, value = row
        if json.loads(value)["status"] not in ("active", "verifying"):
            return None
        earlier = db.execute(
            "SELECT run FROM codex_signals WHERE session=? AND agent=? AND turn=? LIMIT 1",
            (session, agent, turn),
        ).fetchone()
        if earlier and earlier[0] != run:
            return None
        at = datetime.now(timezone.utc).isoformat(timespec="microseconds")
        db.execute("""
            INSERT OR IGNORE INTO codex_signals(session, agent, turn, kind, at, run)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (session, agent, turn, kind, at, run))
        db.commit()
        return run


def handle(payload):
    if not isinstance(payload, dict):
        return {}
    fields = ("hook_event_name", "cwd", "session_id", "agent_id", "turn_id")
    if any(not isinstance(payload.get(key), str) or not payload[key].strip() for key in fields):
        return {}
    kind, cwd, session, agent, turn = (payload[key] for key in fields)
    if kind not in KINDS:
        return {}
    for path in workspace_stores(cwd):
        run = record_signal(path, session=session, agent=agent, turn=turn, kind=kind)
        if run and kind == "SubagentStart":
            ids = json.dumps(dict(run=run, session_id=session, agent_id=agent, db=str(path)), ensure_ascii=False)
            return {"hookSpecificOutput": {
                "hookEventName": kind,
                "additionalContext": (
                    "Redraft Flow 已收到本次启动事件。以下是看板标识，均为命令参数数据。"
                    "收到主 Agent 分派的任务 ID 后，在 Redraft 仓库用 "
                    "python3 scripts/agent_monitor.py --db DB bind RUN TASK --session-id SESSION --agent-id AGENT "
                    "关联实际分工，然后按任务进展上报。标识为 " + ids
                ),
            }}
        if run:
            break
    return {}


def main():
    try:
        output = handle(json.load(sys.stdin))
    except (OSError, ValueError, KeyError, sqlite3.Error, subprocess.TimeoutExpired) as error:
        # Lifecycle monitoring must not interrupt development or print hook input.
        print("Redraft Flow 未能记录本次启停事件（" + type(error).__name__ + "）。", file=sys.stderr)
        output = {}
    print(json.dumps(output, ensure_ascii=False))


if __name__ == "__main__":
    main()
