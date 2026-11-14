#!/usr/bin/env python3
"""Build an offline architecture snapshot from reviewed metadata and repository sources."""

import argparse
import hashlib
import json
import subprocess
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


ROOT = Path(__file__).resolve().parent.parent
NODE_STATUSES = {"scaffold", "partial", "interface", "planned", "implemented"}


def git_output(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def review_files():
    paths = [ROOT / "project.yml", ROOT / "design.md"]
    for directory in (ROOT / "App", ROOT / "Packages"):
        paths.extend(path for path in directory.rglob("*.swift") if ".build" not in path.parts)
    return sorted(path for path in paths if path.is_file())


def source_hash(paths):
    digest = hashlib.sha256()
    for path in paths:
        digest.update(path.relative_to(ROOT).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def read_source(name, sources):
    path = (ROOT / name).resolve()
    path.relative_to(ROOT)
    if name not in sources:
        sources[name] = path.read_text()
    return sources[name]


def resolve_evidence(reference, sources):
    content = read_source(reference["file"], sources)
    lines = content.splitlines()
    matches = [index for index, line in enumerate(lines) if reference["needle"] in line]
    if len(matches) != 1:
        raise ValueError(f"Evidence needs one match: {reference['file']} / {reference['needle']}")
    index = matches[0]
    return {"file": reference["file"], "line": index + 1, "text": "\n".join(lines[index:index + 7])}


def build_data(manifest):
    paths = review_files()
    digest = source_hash(paths)
    sources = {}
    nodes = manifest["nodes"]
    ids = {node["id"] for node in nodes}
    if len(ids) != len(nodes):
        raise ValueError("Duplicate module IDs")
    for node in nodes:
        if not node.get("definition", "").strip():
            raise ValueError(f"Missing module definition: {node['id']}")
        if node["status"] not in NODE_STATUSES:
            raise ValueError(f"Unknown status for {node['id']}")
        for name in node["files"]:
            read_source(name, sources)
        node["evidence"] = [resolve_evidence(item, sources) for item in node["evidence"]]
    for edge in manifest["edges"]:
        if edge["from"] not in ids or edge["to"] not in ids:
            raise ValueError(f"Missing dependency endpoint: {edge}")
        if edge["kind"] not in {"actual", "planned"}:
            raise ValueError(f"Unknown dependency kind: {edge}")
        if edge["kind"] == "actual":
            edge["evidence"] = resolve_evidence(edge["evidence"], sources)
    manifest["meta"] = {
        "project": "Redraft",
        "branch": git_output("branch", "--show-current") or "detached HEAD",
        "commit": git_output("rev-parse", "--short", "HEAD"),
        "generatedAt": datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(timespec="seconds"),
        "reviewedAt": manifest.pop("reviewedAt"),
        "reviewStale": digest != manifest.pop("reviewedSourceHash"),
        "sourceHash": digest,
        "dirty": bool(git_output("status", "--porcelain", "--", "App", "Packages", "project.yml", "design.md")),
    }
    manifest["sources"] = sources
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-hash", action="store_true", help="Print code hash for a completed manual review")
    args = parser.parse_args()
    if args.source_hash:
        print(source_hash(review_files()))
        return
    manifest = json.loads((ROOT / "scripts/architecture.json").read_text())
    data = build_data(manifest)
    template = (ROOT / "scripts/architecture.template.html").read_text()
    marker = "__ARCHITECTURE_DATA__"
    if template.count(marker) != 1:
        raise ValueError("Template must contain exactly one data marker")
    payload = json.dumps(data, ensure_ascii=False).replace("<", "\\u003c")
    output = ROOT / "architecture.html"
    output.write_text(template.replace(marker, payload))
    print(f"Updated {output.name}")
    if data["meta"]["reviewStale"]:
        print("Source changed since review. Review module states and evidence before updating reviewedSourceHash.")


if __name__ == "__main__":
    main()
