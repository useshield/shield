# Download egress: threat model and architecture

**Goal:** you can download videos you explicitly queued at any time, while normal YouTube browsing stays blocked by Shield. This exception must not weaken root authority, committed schedules, hosts enforcement or the signing trust model.

## 1. Download paths in the code

There are two ways a download can run. Only the first is used outside development.

**Contained downloads** (`Kairos/StudyContainment.swift`, §4):

- On in release candidate builds (`SHIELD_RC`). A development build uses them only when launched with `SHIELD_CONTAINED_DOWNLOADS=1`, so test hosts never do.
- Never available in UI Review.
- Available only when the video library is turned on, the bundled broker (`Contents/Helpers/ShieldEgressBroker`) and `/usr/bin/sandbox-exec` exist, and yt-dlp, deno, ffmpeg and ffprobe are found.

**Development worker** (uncontained):

- An XPC service, `com.kairos.ShieldDevelopment.StudyWorker`, built only by `scripts/build_development_worker.sh`.
  - Its entitlements are exactly `app-sandbox` + `network.client` (`Configuration/StudyWorker.entitlements`).
  - The helpers (yt-dlp, deno, ffmpeg, ffprobe, `StudyToolLauncher`) use `app-sandbox` + `inherit` (`Configuration/SandboxInherited.entitlements`), so they inherit **unrestricted outbound networking**. Nothing controls their destinations.
- It must be turned on for each session.
- It refuses whenever committed policy blocks YouTube (`ShieldViewModel.studyPolicyBlockReason`), and refuses on any Mac with an installed Shield service (`StudyInstalledAuthorityGuard`). So it never runs alongside a YouTube block.

**In every process, the system resolver honours Shield's hosts block:** `www.youtube.com` → `0.0.0.0`, `::1`. A tool using the system resolver therefore fails during blocked hours, which is fail-closed.

## 2. Controls: app-level vs OS-enforced

| Control | Kind | Enough alone? | Why |
|---|---|---|---|
| `com.apple.security.network.client` | OS (App Sandbox) | **No** | Allows *every* destination. |
| Video-ID validation, fixed yt-dlp argv | App-level | No | The tool, its JS runtime or ffmpeg can contact any host the extractor returns. |
| yt-dlp `--proxy`, `--source-address`, DoH inside the tool | App-level | No | The tool may ignore them; subprocesses (ffmpeg on HLS/DASH URLs) don't inherit them. |
| **Seatbelt (SBPL) profile on the tool tree** | **OS-enforced** | Partly | The kernel enforces it and children inherit it. SBPL can't name remote hosts (only `localhost`/`*`), so it can confine traffic to a loopback broker but can't allowlist YouTube itself. |
| **Allowlisting egress broker** (separate small process) | App-level policy in an isolated, minimal process | Only combined with SBPL | It is the only thing the tool tree can reach, so its allowlist becomes the effective egress policy. |
| NetworkExtension `NEFilterDataProvider` | OS-enforced, per flow, per signing identity | Yes (strongest) | Needs the Network Extension entitlement (Developer ID provisioning), system-extension approval, and a privileged install. |
| PF anchor with a dedicated worker uid | OS-enforced | Yes, by IP only | Needs root plus `pf.conf` changes. IP-based rules break on CDN rotation unless the broker updates them. |

## 3. Sandbox measurements

`scripts/probe_download_egress.sh <outdir>` runs unprivileged probes under a profile that allows outbound traffic only to `localhost:47811` and denies the `dnssd` and `mDNSResponder` mach services. Expected results:

| Probe | Unsandboxed | Sandboxed |
|---|---|---|
| loopback broker port | allowed | **allowed** |
| another loopback port | allowed | **denied** |
| TCP 1.1.1.1:443 | allowed | **denied** |
| TCP [2606:4700:4700::1111]:443 | allowed | **denied** |
| UDP 8.8.8.8:53 (DNS/QUIC) | allowed | **denied** |
| resolve `example.com` (not in hosts) | allowed | **denied** |
| open listening socket (local relay) | allowed | **denied** |
| child `curl https://1.1.1.1/` | allowed | **denied** (sandbox inherited) |

Also found:

- **Nested sandbox apply is refused.** An App-Sandboxed process cannot narrow its children's network further. The SBPL profile must be applied by a parent that is *not* already App-Sandboxed.
- Resolving `www.youtube.com` inside the sandbox returns the local hosts-file answer (`0.0.0.0`/`::1`) without any network.
- SBPL can also restrict traffic to a single Unix socket path.

## 4. Architecture

```
Shield app (not App-Sandboxed; holds the policy gate and the user's approval)
  ├─ /usr/bin/sandbox-exec -f <tool profile> → yt-dlp --proxy <broker>
  │     └─ deno, ffmpeg, ffprobe (profile inherited)
  │     profile: outbound ONLY localhost:<broker-port>; no listen; no DNS mach services;
  │              writes only in the job's staging folder; no reads in the home folder
  │              outside staging; only the four tools may run; no Apple Events or LaunchServices
  └─ ShieldEgressBroker (only process with real network; small reviewed Swift)
        one per yt-dlp run; HTTP CONNECT proxy on 127.0.0.1:<random port>
        random 192-bit Proxy-Authorization per run, checked in constant time
        allowlist: www.youtube.com, youtubei.googleapis.com, i.ytimg.com, www.google.com (exact)
                   *.googlevideo.com (strict subdomains)
        port 443 only; rejects IP literals; peeks the TLS ClientHello and requires SNI == CONNECT host
        resolves allowlisted names with DNS-over-HTTPS to fixed resolver IPs, never the system resolver
        accepts only public unicast IPv4 answers
        ≤ 8 tunnels, ≤ 3 GB per tunnel, 60 s idle timeout; logs every decision
        lifetime ≤ 3,900 s; refuses after it ends, and is stopped when the job ends
```

What each threat is handled by:

- **Direct connections, alternate IPs, IPv6, UDP/QUIC, DNS tunnelling from the tools:** the SBPL kernel denial (§3).
- **Redirects and CDN rotation:** every hop is a new CONNECT that the broker re-checks. `*.googlevideo.com` is a suffix rule; other names are exact.
- **Domain fronting:** the broker requires the SNI to match the CONNECT host.
- **ffmpeg HLS/DASH network fetch:** it is either routed through the same proxy or denied by SBPL, so it fails closed.
- **Deno:** yt-dlp runs it with `--no-remote-components`. Any Deno network attempt goes through the broker or is denied.
- **Reading personal files:** the profile denies reads in the home folder outside the job's staging folder and the tools themselves.
- **Browsers:** they still use the system resolver and hosts. The broker isn't a system proxy, has a per-run port and secret, and exists only during a job.

`www.google.com` is on the allowlist because yt-dlp's first watch-page request goes there. Shield's hosts block does not cover that host, so allowing it weakens nothing.

## 5. Design decisions

The contained path makes three deliberate, scoped choices:

1. **Seatbelt for the tools, not App Sandbox `inherit`.** Nested sandbox apply is refused (§3), so the profile must be applied by a process that isn't App-Sandboxed. The app runs the tools through `sandbox-exec`.
2. **The broker resolves allowlisted names itself, with DNS-over-HTTPS.** This is an exception to hosts enforcement for this one process only. Every other process, including browsers, still gets the hosts-file answer.
3. **The policy gate lets contained fetches run while YouTube is blocked.** `studyPolicyBlockReason(contained: true)` does not refuse because of a YouTube block, since contained fetches never open YouTube to the rest of the Mac. It still requires fresh authority evidence: the app's last refresh within 30 s and the service's last verification within 90 s. Root authority, schedules and the hosts writer stay unchanged.

Alternatives that need privileges are documented only: NetworkExtension (Developer ID, the Network Extension entitlement and system-extension approval) or PF with a dedicated uid (root).

## 6. Implementation

- **`Kairos/EgressPolicy.swift`**: the pure broker policy.
  - strict CONNECT parsing (4 KiB cap)
  - a constant-time credential check
  - rejection of every IPv4 form `inet_aton` accepts (dotted, decimal, octal, hex), plus IPv6 and zone literals
  - exact names or strict subdomain suffixes, and a port allowlist
  - a job expiry
  - a TLS ClientHello SNI parser, which requires the SNI to equal the CONNECT host
  - `EgressResolverAnswer`, which takes only public unicast IPv4 addresses from a DoH answer
- **`EgressBroker/main.swift`**: a loopback-only Network.framework CONNECT broker.
  - `SHIELD_BROKER_RESOLVER=doh` resolves allowlisted names through `https://1.1.1.1/dns-query`, with `1.0.0.1` as fallback.
  - Without a resolver, every allowed CONNECT to a real host gets `502` (`resolverNotApproved`).
  - Test mode accepts only `*.shield.test → 127.0.0.1` upstreams, and can't be combined with DoH.
  - Denials log the requested host, never credentials, so the allowlist can be measured.
- **`Kairos/StudyContainment.swift`**:
  - generates the tool profile (`toolProfile`) and an offline profile with no network at all (`offlineProfile`)
  - starts a fresh broker for every yt-dlp run, with a random port, a random credential and a bounded lifetime
  - provides `StudyContainedFetcher`
  - converts downloads Apple's player can't play to H.264/AAC MP4 with ffmpeg under the offline profile (`ContainedMediaRepairer`)
- **`YTDLPRestrictedFetcher`** (`Kairos/StudyDownloader.swift`) runs yt-dlp through `/usr/bin/sandbox-exec -f <profile>` with `--proxy`. deno and ffmpeg inherit the sandbox.
- **Optional sign-in for YouTube's bot check** (`StudyCookies`): you may export a `cookies.txt` from a dedicated Google account. Shield never handles a password. Each job gets a private copy inside its staging folder, holding only YouTube and Google cookies, so the sandbox write rule is unchanged. The copy is deleted when the job ends.
- **Packaging**: `scripts/build_egress_broker.sh` builds the broker into `Contents/Helpers/ShieldEgressBroker`; the release packagers sign it.

## 7. Testing

- `ShieldTests/EgressPolicyTests.swift` and `ShieldTests/StudyContainmentTests.swift` (Swift Testing).
- `scripts/test_egress_broker.sh <outdir>`: adversarial cases with a Seatbelt-confined `curl` against a local TLS upstream. No YouTube traffic.
  - an allowed host succeeds, with real TLS through the tunnel
  - wrong or missing credential → 407
  - non-allowlisted name, IPv4 literal, IPv6 literal, or wrong port → 403
  - domain fronting → `serverNameMismatch`
  - plaintext inside the tunnel → `notTLS`
  - direct dial to the upstream, direct dial to 1.1.1.1, and DNS are all blocked by the sandbox
  - a `www.youtube.com` CONNECT without a resolver → 502 (`resolverNotApproved`)
  - an expired broker → refused
  - the system resolver still returns `0.0.0.0`/`::1` for YouTube
- `scripts/test_contained_tools.sh`: the real yt-dlp, deno and ffmpeg with the built broker. Check each failure for its reason, not just that it failed.
  - yt-dlp direct → DNS denied
  - yt-dlp via the broker to a non-allowlisted site → `hostNotAllowed`
  - ffmpeg and deno direct → `Operation not permitted`
  - IP literal via the broker → `ipLiteral`
  - wrong credential → 407
  - `nslookup` → denied
  - write outside staging → denied; write inside staging → allowed
  - YouTube `generate_204` via the broker → 200
  - the system resolver still returns `0.0.0.0`/`::1` for YouTube
- Oversized and malformed CONNECT requests are covered by the unit tests. Still worth adding to the script: a slow-loris CONNECT against the running broker, and a redirect to a non-allowlisted host.
- Throughout a real download, the system resolver should still return `0.0.0.0`/`::1` for `youtube.com`, and an unmodified browser should still fail to load YouTube.

A successful download is **not** evidence of security. Only the negative matrix is.

## 8. Limits

- A same-user process that obtains the per-run secret could use the broker for allowlisted YouTube hosts while a job runs. That is no easier than known resolver bypasses such as Chrome's `--host-resolver-rules`, and it is bounded in time. The NetworkExtension variant would close it by keying on the client's code signature.
- The development worker path has no destination control (§1). It is kept out of release builds and refuses whenever YouTube is blocked.
- YouTube may answer "Sign in to confirm you're not a bot" (HTTP 429 from `www.google.com/sorry`). That check comes from YouTube, not from Shield's containment: the broker log shows the connections allowed. The optional sign-in file (§6) is the supported answer. Shield does not try to get around the check.
- Download only videos you are authorized to download.
