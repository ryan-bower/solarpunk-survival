#!/usr/bin/env python3
"""Post-patch symbol diff for UE4SS dumps.

After a game update, regenerate UE4SS dumps and run this against the previous dump to get a precise
punch-list of what changed. With --mapping, it flags exactly which symbols referenced in
mapping.lua have vanished from the new dump (i.e. the hooks you must re-map).

Usage:
    python tools/dump-diff.py dumps/<old> dumps/<new> [--mapping mod/SolarpunkSurvival/Scripts/mapping.lua]

It scans all text files under each dump dir and extracts identifier-like tokens (class / function /
property names). Format-agnostic by design, so it works on CXX headers or object dumps.
"""
import argparse
import os
import re
import sys

TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]{2,}")
TEXT_EXT = {".hpp", ".h", ".cpp", ".txt", ".log", ".usmap", ".lua", ".json", ".ini", ""}


def collect_tokens(root):
    tokens = set()
    if not os.path.isdir(root):
        sys.exit(f"not a directory: {root}")
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            ext = os.path.splitext(fn)[1].lower()
            if ext and ext not in TEXT_EXT:
                continue
            path = os.path.join(dirpath, fn)
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as f:
                    for line in f:
                        tokens.update(TOKEN.findall(line))
            except OSError:
                pass
    return tokens


def mapping_symbols(path):
    """Extract quoted string values from mapping.lua (class/function/property names)."""
    syms = set()
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            src = f.read()
    except OSError as e:
        sys.exit(f"cannot read mapping: {e}")
    # only look at non-comment lines
    for line in src.splitlines():
        code = line.split("--", 1)[0]
        for m in re.findall(r'"([A-Za-z_][A-Za-z0-9_:]*)"', code):
            # split "Class:Function" into both parts
            for part in m.split(":"):
                if part:
                    syms.add(part)
    return syms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("old")
    ap.add_argument("new")
    ap.add_argument("--mapping", help="path to mapping.lua to focus the report")
    ap.add_argument("--show-added", action="store_true", help="also list newly-added tokens")
    args = ap.parse_args()

    old = collect_tokens(args.old)
    new = collect_tokens(args.new)
    removed = old - new
    added = new - old

    print(f"old tokens: {len(old)}   new tokens: {len(new)}")
    print(f"removed: {len(removed)}   added: {len(added)}")

    if args.mapping:
        syms = mapping_symbols(args.mapping)
        broke = sorted(s for s in syms if s in removed)
        still = sorted(s for s in syms if s in new)
        print("\n=== mapping.lua symbols ===")
        print(f"still present in new dump: {len(still)}")
        if broke:
            print(f"!! GONE / RENAMED in new dump ({len(broke)}) — RE-MAP THESE:")
            for s in broke:
                print(f"   - {s}")
        else:
            print("all mapped symbols still present — mapping likely still valid.")

    if args.show_added and added:
        print("\n=== added tokens (sample) ===")
        for s in sorted(added)[:100]:
            print(f"   + {s}")


if __name__ == "__main__":
    main()
