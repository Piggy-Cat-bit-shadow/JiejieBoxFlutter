#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Collect the pinned baseline manifest for the JiejieBox Flutter client.

Writes baseline/manifest.json: repository commits/trees, submodule pin, toolchain
versions and SHA-256 of the UI/API files this project derives from. The manifest
is the contract that A/B/C/R verify against (see tools/verify_baseline.py).

Usage:
    python tools/collect_baseline.py
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT = REPO_ROOT / "baseline" / "manifest.json"

REPOS = [
    {
        "name": "FlClash",
        "role": "UI/layout/component authority (Prism v0.9.3)",
        "path": Path(r"C:\JJ\repos\FlClash"),
        "ref": "v0.9.3",
        "expected_commit": "be84736605527034689c95bf27828ff27d912c5e",
        "submodules": [
            {
                "path": "plugins/prism_ui",
                "commit": "63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185",
            },
            {
                "path": "core/Clash.Meta",
                "commit": "024245dc72bc92f48237f865119afe0cd53ac9e6",
                "note": "not initialised: upstream submodule URL is SSH; UI work does not need it",
            },
        ],
        "files": [
            "lib/common/layout.dart",
            "lib/common/constant.dart",
            "lib/common/window.dart",
            "lib/views/profiles/profiles.dart",
            "lib/views/profiles/add.dart",
            "lib/views/navigation.dart",
            "lib/pages/home.dart",
            "lib/features/form/form_row.dart",
            "lib/ui/scaffold/scaffold.dart",
            "lib/views/dashboard/layout.dart",
            "lib/views/proxies/common.dart",
        ],
    },
    {
        "name": "prism_ui",
        "role": "Prism design-system source (FlClash submodule pin)",
        "path": Path(r"C:\JJ\repos\prism_ui"),
        "ref": "63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185",
        "expected_commit": "63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185",
        "submodules": [],
        "files": [
            "lib/metrics.dart",
            "lib/typography.dart",
            "lib/shape.dart",
            "lib/measure.dart",
            "lib/context.dart",
            "lib/sidebar.dart",
            "lib/button.dart",
            "lib/view_scope.dart",
        ],
    },
    {
        "name": "B-box",
        "role": "feature-cut reference only (not a visual authority)",
        "path": Path(r"C:\JJ\repos\B-box"),
        "ref": "newui",
        "expected_commit": "5685b141efdbe2b161702c6045ee6d46dc25d3e8",
        "submodules": [],
        "files": [
            "flutter/lib/components/form.dart",
            "flutter/lib/components/profile_card.dart",
            "libbox/ui_nodes.go",
        ],
    },
    {
        "name": "JiejieBox",
        "role": "kernel/API authority (testing branch)",
        "path": Path(r"C:\JJ\repos\JiejieBox"),
        "ref": "testing",
        "expected_commit": "4dc2593fbc1bf736afd1d79a3fdec5f7371db328",
        "submodules": [],
        "files": [
            "experimental/libbox/config.go",
            "experimental/libbox/analysis.go",
            "experimental/libbox/command_client.go",
            "experimental/libbox/command_types.go",
            "provider/parser/parser.go",
            "provider/parser/link.go",
            "option/provider.go",
            "option/group.go",
            "go.mod",
        ],
    },
]


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
    repos = []
    for spec in REPOS:
        path = spec["path"]
        if not path.exists():
            print(f"ERROR: missing clone {path}", file=sys.stderr)
            return 1
        commit = git(path, "rev-parse", "HEAD")
        tree = git(path, "rev-parse", "HEAD^{tree}")
        if commit != spec["expected_commit"]:
            print(
                f"ERROR: {spec['name']} commit {commit} != expected {spec['expected_commit']}",
                file=sys.stderr,
            )
            return 1
        dirty = git(path, "status", "--porcelain")
        files = {}
        for rel in spec["files"]:
            target = path / rel
            files[rel] = sha256_of(target) if target.exists() else None
        repos.append({
            "name": spec["name"],
            "role": spec["role"],
            "remote": git(path, "remote", "get-url", "origin"),
            "path": str(path),
            "ref": spec["ref"],
            "commit": commit,
            "tree": tree,
            "commit_date": git(path, "log", "-1", "--format=%cI"),
            "dirty": bool(dirty),
            "submodules": spec["submodules"],
            "files_sha256": files,
        })

    manifest = {
        "schema": "jiejiebox-flutter-baseline/1",
        "phase": "P0",
        "owner": "A (UI)",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "toolchain": {
            "flutter": "3.50.0 (stable, framework ab2912035e, 2026-11-09)",
            "dart": "3.14.0",
            "flutter_sdk_path": r"C:\JJ\tools\flutter",
            "pub_cache": r"C:\JJ\pub-cache",
            "go": "not installed on this machine (JiejieBox work is read-only here)",
            "rust": "not installed (rust_api native-assets hook cannot build)",
        },
        "flclash_pubspec_constraints": {
            "environment_sdk": ">=3.10.0 <4.0.0",
            "lock_dart": ">=3.13.2 <4.0.0",
            "lock_flutter": ">=3.47.2",
        },
        "repos": repos,
        "notes": [
            "No third-party source is vendored yet; A1 decides the vendoring layout.",
            "Never edit the clones above; changes go only into this repository.",
            "FlClash core/Clash.Meta is intentionally uninitialised (SSH submodule, UI work does not need it).",
        ],
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"OK: wrote {OUT}")
    for repo in repos:
        print(f"  {repo['name']:10s} {repo['commit']} dirty={repo['dirty']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
