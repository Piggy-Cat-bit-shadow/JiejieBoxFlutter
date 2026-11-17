#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verify the local clones against baseline/manifest.json.

Fails (exit 1) when a commit, tree, submodule pin or hashed file drifted, so a
reviewer can prove the UI evidence was produced from the pinned sources.

Usage:
    python tools/verify_baseline.py
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST = REPO_ROOT / "baseline" / "manifest.json"


def git(path: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(path), *args],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} in {path} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    if not MANIFEST.exists():
        print(f"ERROR: missing manifest {MANIFEST}; run tools/collect_baseline.py", file=sys.stderr)
        return 1
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    failures: list[str] = []
    checked_files = 0
    for repo in manifest["repos"]:
        path = Path(repo["path"])
        if not path.exists():
            failures.append(f"{repo['name']}: missing clone at {path}")
            continue
        commit = git(path, "rev-parse", "HEAD")
        tree = git(path, "rev-parse", "HEAD^{tree}")
        if commit != repo["commit"]:
            failures.append(f"{repo['name']}: commit {commit} != {repo['commit']}")
        if tree != repo["tree"]:
            failures.append(f"{repo['name']}: tree {tree} != {repo['tree']}")
        dirty = bool(git(path, "status", "--porcelain"))
        if dirty:
            failures.append(f"{repo['name']}: working tree is dirty (baseline must stay clean)")
        for sub in repo.get("submodules", []):
            if not (path / sub["path"]).exists():
                failures.append(f"{repo['name']}: submodule path {sub['path']} missing")
        for rel, expected in repo["files_sha256"].items():
            target = path / rel
            if not target.exists():
                failures.append(f"{repo['name']}: missing {rel}")
                continue
            actual = sha256_of(target)
            checked_files += 1
            if actual != expected:
                failures.append(f"{repo['name']}: {rel} sha256 drifted")
    if failures:
        print(f"FAILED: {len(failures)} baseline difference(s)")
        for item in failures:
            print("  " + item)
        return 1
    print(
        f"OK: {len(manifest['repos'])} repositories and {checked_files} files match "
        f"baseline/manifest.json"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
