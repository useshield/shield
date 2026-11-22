# Reviewed real worker toolchain input contract

No real toolchain is bundled by this source campaign. No versions, download
successes or vendor authenticity are inferred from the synthetic lifecycle tools.
This document describes input to the single consolidated native workflow; it is
not permission to fetch tools, install services or bypass current restrictions.

## Exact files

The selected private tools directory must contain the reviewed standalone Mach-O
executables `yt-dlp`, `deno`, `ffmpeg`, `ffprobe`, plus these two JSON records:

- `reviewed-sha256.json`: exactly those four names mapped to lowercase, 64-character
  SHA256 digests of the **original input bytes**.
- `toolchain-review.json`: schemaVersion 1 and exactly those names under `tools`.
  Each entry must contain exactly `version`, `sha256`, `sourceURL`, `license`.

Example shape only; the placeholders intentionally are not valid approved inputs:

```json
{
  "schemaVersion": 1,
  "tools": {
    "yt-dlp": {"version": "REVIEWED RELEASE", "sha256": "EXACT INPUT SHA256", "sourceURL": "https://UPSTREAM/EXACT-ASSET", "license": "REVIEWED LICENSE"},
    "deno": {"version": "REVIEWED RELEASE", "sha256": "EXACT INPUT SHA256", "sourceURL": "https://UPSTREAM/EXACT-ASSET", "license": "REVIEWED LICENSE"},
    "ffmpeg": {"version": "REVIEWED RELEASE", "sha256": "EXACT INPUT SHA256", "sourceURL": "https://UPSTREAM/EXACT-ASSET", "license": "REVIEWED LICENSE"},
    "ffprobe": {"version": "MATCHING RELEASE", "sha256": "EXACT INPUT SHA256", "sourceURL": "https://UPSTREAM/EXACT-ASSET", "license": "REVIEWED LICENSE"}
  }
}
```

Use exact pinned release/asset locations and independently reviewed digest/source
information, not a moving “latest” URL. The application does not retrieve these
URLs. The provenance record is a human review input, not cryptographic proof of
publisher authenticity. Record any distribution license obligations in the review.
The two manifests must agree; duplicate JSON keys and unsafe provenance files fail.

## Preparation and measurement

The existing guarded build path validates no symlinks/hardlinks, no group/world
writability, executable permission, 300 MB per-tool bound and Mach-O magic. It
checks actual load commands for no LC_RPATH/LC_DYLD_ENVIRONMENT and only system
library dependencies. Do not strip these checks to accommodate a failing binary;
a compatible, reviewed build is required. A Mach-O header alone cannot establish
that an embedded runtime will work in the sandbox.

The exact input hashes are retained in sealed Resources. Helper signing changes
bytes, so `tool-hashes.json` separately records the signed binaries. Helpers must
contain exactly four tools and StudyToolLauncher, each with App Sandbox/inherit;
the worker has exactly App Sandbox/network.client. Metadata is never executable
content in Helpers. Host certificate pinning and exact worker code identity remain.

Runtime version probes execute inside the worker through the same bounded
launcher. Current compatibility checks require dated yt-dlp >= 2025.01.01, Deno
2.x, matching FFmpeg/FFprobe major versions >= 6. These are compatibility bounds,
not recommendations to use an obsolete release. Review a current release and its
behavior independently. No shell/Python wrapper, arbitrary PATH fallback, remote
component update, browser cookies or unrestricted argument forwarding is added.

The optional real-tool stage transfers an explicitly permitted video's actual
bytes through the worker and decodes them with NativeLocalMediaValidator. Its
private evidence includes sealed manifests, actual runtime versions, media hash,
byte length, duration and transcript presence. Failures leave logs/partial data
for diagnosis and cannot create a success receipt. Media stays local rather than
being included in the compact sharing ZIP.

Before any real beta acceptance, also measure actual-tool file denial, subprocess
and descendant cancellation, interruption recovery, metadata/title handling and
removed/private/geo-restricted failure behavior. Synthetic C boundary tests are
not a substitute for those actual binaries.

## Unchanged network limit

Standard `network.client` is broad outbound access. Approved IDs and canonical
URLs are request constraints, not OS destination authorization. Strict production
fetching remains disabled. The real smoke stage is restricted to an empty
disposable Mac; Development session consent cannot authorize downloads around
installed RC-77 commitments. A real-download smoke PASS still leaves application
policy integration, destination authorization and production acceptance false.
