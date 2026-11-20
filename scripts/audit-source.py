#!/usr/bin/env python3
"""Check the exact Git blobs in the index or a release history. Never print matching data."""
import argparse
from pathlib import PurePosixPath
import re
import subprocess
import sys

POLICY = {
    "user home path": rb"/Users/" + rb"(?!Shared/|runner/)[A-Za-z0-9_.-]+/",
    "private key": rb"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----",
    "access credential": rb"(?:gh[pousr]_[a-zA-Z0-9]{30,}|github_pat_[A-Za-z0-9_]{45,}|sk-(?:proj-)?[A-Za-z0-9_-]{32,}|xox[baprs]-[A-Za-z0-9-]{24,})",
}
DENY_PART = {".dsh", "PrivateProvenance", "node_modules", ".DS_Store", ".env",
             "Resources/Pet", "docs/local", "docs/assets", "experiments", "dist", ".build"}
DENY_SUFFIX = {".dmg", ".zip", ".tgz", ".xpi", ".pdf", ".log", ".p12", ".key", ".p8", ".pem", ".sqlite", ".db", ".plist"}
BINARY = {".woff", ".woff2", ".ttf", ".png"}

def git(*args):
    return subprocess.check_output(["git", *args])

def inspect_tree(entries, seen):
    bad = False
    for entry in entries.split(b"\0"):
        if not entry:
            continue
        header, name = entry.split(b"\t", 1)
        mode, _, oid = header.decode().split()
        path = PurePosixPath(name.decode())
        if mode not in ("100644", "100755") or path.suffix in DENY_SUFFIX or any(
            item in DENY_PART for item in (*path.parts, *(str(p) for p in path.parents))
        ):
            print(f"{path}: excluded path/type")
            bad = True
            continue
        if oid in seen:
            continue
        seen.add(oid)
        data = git("cat-file", "blob", oid)
        if b"\x00" in data:
            permitted = ((path.suffix in BINARY - {".png"} and str(path.parent) == "Resources/Transcript/vendor/katex/fonts")
                         or str(path) == "docs/images/research-transcript.png")
            if not permitted:
                bad = True
                print(f"{path}: unreviewed binary")
        for reason, pattern in POLICY.items():
            if re.search(pattern, data):
                print(f"{path}: {reason}")
                bad = True
    return bad

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--history", action="store_true", help="Check all commits reachable from local refs as well")
    args = p.parse_args()
    seen = set()
    # write-tree freezes exactly the reviewed staging area, including executable bits.
    trees = [git("write-tree").strip().decode()]
    if args.history:
        trees += git("rev-list", "--all").decode().splitlines()
    failed = False
    for tree in trees:
        failed |= inspect_tree(git("ls-tree", "-rz", tree), seen)
    print(f"Checked {len(seen)} distinct Git blobs.")
    sys.exit(1 if failed else 0)

if __name__ == "__main__":
    main()
