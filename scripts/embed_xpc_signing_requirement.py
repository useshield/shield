#!/usr/bin/env python3
"""Embed a signed XPC requirement without shell or PlistBuddy quoting loss."""
import pathlib
import plistlib
import re
import sys


def embed_requirement(path: pathlib.Path, requirement: str) -> None:
    pattern = r'identifier "com\.kairos\.ShieldAuthority" and cdhash H"[a-f0-9]{40}"'
    if re.fullmatch(pattern, requirement) is None:
        raise ValueError("Unexpected Shield authority signing requirement")
    data = path.read_bytes()
    fmt = plistlib.FMT_BINARY if data.startswith(b"bplist00") else plistlib.FMT_XML
    document = plistlib.loads(data)
    if not isinstance(document, dict):
        raise ValueError("Info.plist must be a dictionary")
    if "ShieldServiceSigningRequirement" in document:
        raise ValueError("Signing requirement already embedded")
    document["ShieldServiceSigningRequirement"] = requirement
    path.write_bytes(plistlib.dumps(document, fmt=fmt, sort_keys=False))
    if plistlib.loads(path.read_bytes())["ShieldServiceSigningRequirement"] != requirement:
        raise ValueError("Signing requirement did not round trip")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: embed_xpc_signing_requirement.py <Info.plist> <requirement>")
    embed_requirement(pathlib.Path(sys.argv[1]), sys.argv[2])
