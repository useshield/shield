#!/bin/bash
set -euo pipefail
# A disposable test pin for the exact signed code, independent of its path.
test "$#" -eq 2
codesign --verify --strict "$1"
codesign -d --verbose=4 "$1" 2>&1 | python3 -c '
import re, sys
identifier = sys.argv[1]
assert re.fullmatch(r"[A-Za-z0-9.-]+", identifier)
metadata = sys.stdin.read()
assert re.search(r"^Identifier=" + re.escape(identifier) + r"$", metadata, re.M)
digest = re.search(r"^CDHash=([a-f0-9]{40})$", metadata, re.M)
assert digest, "No native code-directory hash in signature"
print("identifier \"" + identifier + "\" and cdhash H\"" + digest[1] + "\"")
' "$2"
