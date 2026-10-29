#!/usr/bin/env python3
"""Gjør kompilator- og testfeil i en logg om til GitHub-annotasjoner (synlige i Actions og via API).
Bruk: annotate.py <loggfil> <del-nummer>  (10 feil per del – GitHub viser maks 10 per steg)."""
import re, sys, os

log, part = sys.argv[1], int(sys.argv[2])
if not os.path.exists(log):
    sys.exit(0)
root = os.environ.get("GITHUB_WORKSPACE", "") + "/"
pat = re.compile(r"^(/[^:]+?):(\d+)(?::(\d+))?: (?:fatal )?error: (.*)$")
seen, errors = set(), []
for line in open(log, encoding="utf-8", errors="replace"):
    m = pat.match(line.rstrip())
    if not m:
        continue
    path, ln, col, msg = m.groups()
    key = (path, ln, msg)
    if key in seen:
        continue
    seen.add(key)
    errors.append((path.replace(root, ""), ln, col or "1", msg))

def esc(s):
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")

chunk = errors[(part - 1) * 10: part * 10]
if part == 1:
    print(f"::notice::Fant {len(errors)} unike feil i {os.path.basename(log)}")
for p, ln, col, msg in chunk:
    print(f"::error file={p},line={ln},col={col}::{esc(msg)}")
