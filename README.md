# Shield

A native macOS app for blocking distracting websites and apps on your own Mac, with rules that are easy to make stricter and deliberately slow to loosen. Free and open source.

## What it does

- **Blocks websites and apps** you choose, through a background service:
  - In **Chrome, Brave, Edge, Vivaldi and Firefox**, Shield hands the browser its block list as a browser policy. A blocked site and its subdomains stay blocked in every profile, Incognito and Guest window, whatever DNS, VPN or proxy is set.
  - In **Safari and other apps**, websites are blocked through a managed section of `/etc/hosts`. Shield adds the `www.` version of each site for you.
  - A blocked **app** closes within about two seconds of opening.
- **Kinds of block:**
  - **Permanent** blocks stay until you remove them, and removing one waits 72 hours (you can make that longer, up to 30 days, in Settings).
  - Any new block can be **undone for 10 minutes**, in case you made a mistake.
  - **Until released** blocks end only when you ask, 24 hours later.
  - **Timed** blocks end on their own and can't end early.
- **Daily schedules** set the hours a site is *allowed*; it's blocked the rest of the day. They follow your Mac's time zone: when macOS sets it from your location, schedules switch at once; a time zone changed by hand applies after 24 hours.
- **One rule for every change:** anything stricter applies at once; anything looser waits at least 24 hours. A pending looser change can be cancelled at once ("Keep Current Rules").
- **Categories** organize blocks and schedules. They never change what's blocked.
- **Places:** optional rules for where you are (for example "Go There Today"). Location is used only while such a rule needs it and never leaves your Mac.
- **Video Library (add-on, not in the 1.1 download):** save videos for offline study and watch them with resume, speed and transcripts. The source is here; it isn't part of the release yet. Download only media you're allowed to download; respect each site's terms and the creators' rights.
- **Everything Shield changes on your Mac** is listed in Settings → "What Shield changes on this Mac".

## What's not covered yet

Shield is a commitment tool: it makes giving in slow and deliberate. These gaps are known and planned for the next updates:

- **Safari and other apps** only get the `/etc/hosts` block, so a custom DNS setting, a VPN or a subdomain that isn't listed can still reach a blocked site there.
- **Other browsers** such as Arc and Opera don't read Shield's browser policy yet. Shield only checks how they were started.
- **Other devices** aren't covered. Shield works on the Mac it's installed on.

See [SECURITY.md](SECURITY.md) for how Shield's rules are protected and how to report a problem.

## Requirements

- To run Shield: macOS 26 on Apple silicon.
- To build it: Xcode 27 (macOS 27 SDK). To build an installer: any code-signing identity, including a self-signed one. The service only accepts the exact app build it was installed with.

## Build and run

Development builds use an isolated, simulated backend in a temporary folder. They never touch `/etc/hosts` or an installed service.

```bash
xcodebuild build -project Kairos.xcodeproj -scheme Kairos -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
```

Open `Kairos.xcodeproj` in Xcode and run the **Kairos** scheme for the same thing interactively. Set `SHIELD_VISUAL_FIXTURE=1` and `SHIELD_UI_POLISH_FIXTURE=1` in the scheme's environment for a sample set of blocks and schedules.

## Tests

```bash
# Unit tests (no network, no installed service)
xcodebuild test -project Kairos.xcodeproj -scheme Kairos -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -only-testing:ShieldTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual

# UI flows (drives the app on screen; simulated backend only)
xcodebuild test ... -only-testing:ShieldUITests/ShieldDownloadsFlowTests \
  -only-testing:ShieldUITests/ShieldCategoryFlowTests
```

## Install

Shield isn't notarized by Apple (it's free and has no Apple developer account), so macOS asks you to confirm it once:

1. Download `Shield-1.1.pkg` and `SHA256SUMS` from [Releases](https://github.com/useshield/shield/releases/latest). Optional check: `shasum -a 256 -c SHA256SUMS`.
2. Open the package. macOS says it can't check it; click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Shield-1.1.pkg.
4. Follow the installer and enter your Mac password. Shield installs for the account you're logged in to.

The installer adds the app to `/Applications`, a background service (`/Library/PrivilegedHelperTools`, `/Library/LaunchDaemons`) and its state in `/Library/Application Support/ShieldAuthority`. It writes a marked section of `/etc/hosts` only once you block a website.

**Updates:** Settings → Updates checks this repository's releases when you ask. Shield verifies the download's checksum and its own update signature before opening the installer. Updates keep every block exactly as it was.

**Removing Shield:** Settings → Remove Shield. It waits like removing a permanent block (3 days by default), and until every timed block has ended; "Keep Shield" cancels it. Then Shield takes out its section of `/etc/hosts`, its browser settings, the service and the app, and leaves a note in `/Library/Logs/Shield Removal.txt`. Your Video Library and settings in your home folder are kept. While a block made never-removable exists, Shield can't be removed this way.

**Build it yourself:** `bash scripts/package_public_release.sh <output-folder> "<your signing identity>"` builds the same installer from source. It never installs anything.

## Project layout

| Path | What it is |
|---|---|
| `Kairos/` | The SwiftUI app: views, view model, policy model, backend engine shared with the service |
| `AuthorityService/` | The root service (install, inspect, serve over authenticated XPC) |
| `StudyWorker/`, `EgressBroker/` | Video Library add-on: sandboxed download worker and its allowlisting network broker |
| `ShieldLocationHelper/` | Fallback location sensor for Places |
| `ShieldNetworkFilter/` | Planned network filter for Safari and other apps (not built yet) |
| `ShieldTests/`, `ShieldUITests/` | Unit tests and UI flow tests |
| `scripts/` | Packaging, signing checks and test helpers |
| `docs/` | Architecture and threat-model notes |

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). You may use, study, change and share Shield; copies and changed versions must stay under the same license with their source available.
