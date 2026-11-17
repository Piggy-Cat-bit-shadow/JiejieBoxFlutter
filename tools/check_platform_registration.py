#!/usr/bin/env python3
"""Platform plugin registration audit (P4).

Catches the class of bug where a host plugin is implemented but never attached to
the Flutter engine, or attached twice. It is a static gate: it does not build.
"""
import io
import os
import re
import sys

BASE = os.environ.get("JJBOX_REPO", os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

CHECKS = [
    ("windows", "windows/runner/flutter_window.cpp", r"JjboxPluginRegisterWithRegistrar\(", 1),
    ("macos", "macos/Runner/MainFlutterWindow.swift", r"JjboxMacHostPlugin\.register\(", 1),
    ("ios", "ios/Runner/AppDelegate.swift", r"JjboxHostPlugin\.register\(", 1),
    ("android", "android/app/src/main/kotlin/com/jiejiebox/app/MainActivity.kt", r"JjboxPlugin\(", 1),
]

problems = 0
for platform, rel, pattern, expected in CHECKS:
    path = os.path.join(BASE, rel.replace("/", os.sep))
    if not os.path.isfile(path):
        print("FAIL %-8s missing file %s" % (platform, rel))
        problems += 1
        continue
    text = io.open(path, encoding="utf-8").read()
    found = len(re.findall(pattern, text))
    if found != expected:
        print("FAIL %-8s %s has %d registration site(s), expected %d" % (platform, rel, found, expected))
        problems += 1
    else:
        print("PASS %-8s %d registration site" % (platform, found))

print("registration audit: %d problem(s)" % problems)
sys.exit(1 if problems else 0)
