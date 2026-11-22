# Shield: blocking apps — design

## What it does

- Blocks chosen apps, such as a game, Steam, Discord or a streaming app, either at all times or outside allowed hours.
- Uses the same rules as website blocks:
  - allowed hours are stored as the blocked complement, in the service's fixed time zone
  - stricter changes apply at once
  - anything looser waits at least 24 hours
  - when Shield can't verify its state, everything stays blocked
- A rule may hold sites and apps together. For example, a "YouTube" rule could cover youtube.com and a YouTube desktop app.

## How macOS lets an app be blocked

| Way | Stops the app before it opens | Needs | Verdict |
|---|---|---|---|
| **Watcher in the existing root service** (stage 1) | No: it closes the app within about two seconds of opening | Nothing from Apple. Ships with the service | **What Shield uses** |
| **Endpoint Security** (stage 2) | Yes | A restricted entitlement Apple must grant, a paid developer account, and Full Disk Access approval. Building it without the entitlement means turning SIP off, which belongs in a throwaway VM | Possible later upgrade |
| Screen Time API (ManagedSettings) | — | iOS / Mac Catalyst only. Authorization fails at runtime on Mac Catalyst | Not usable |
| Configuration profiles (MDM app restrictions) | Partly | The restrictions payload is deprecated and unreliable on current macOS | Not usable |
| Built-in Screen Time limits, with a passcode someone else holds | Yes | No code | A good extra layer you can set up alongside Shield |

## Limits

- An administrator can stop either mechanism.
- If an Endpoint Security client stops, macOS allows every launch.
- Unlike `/etc/hosts`, which keeps blocking after the service stops, app blocking needs a running process. Tamper evidence (`Kairos/ServiceGapEvidence.swift`) records when the service was not running while the Mac was awake. It can't prevent the stop.
- Scripts, command-line tools and web apps inside a browser are not covered by app rules.

## Matching an app

A target is taken from a real `.app` the user picks. Its bundle ID and team ID come from the app's own code signature. A running app matches when either is true:

- **It carries the target's bundle ID, or a helper ID under it**, for example `com.google.Chrome.helper` or Electron renderers. This also catches a renamed or re-signed copy, because re-signing strips the team.
- **It is signed by the target's team with the target's identifier**, which catches a copy whose bundle ID was edited.

Matching too much is the safe direction for a block. Path and CDHash are not used: copying the app defeats path matching, and every update changes the CDHash.

## Apps that can never be blocked

`AppBlockSafety` in `Kairos/AppBlocking.swift` holds these lists.

- **Mac essentials:** Finder, Dock, login window, SystemUIServer, Control Center, Notification Center, Window Manager and SecurityAgent, plus System Settings and Terminal, which are needed for recovery.
- **Shield itself:** any `com.kairos.*` bundle ID.
- **Captive Network Assistant**, so you can still join a Wi-Fi network that needs a login page.
- **Web browsers** (Safari, Chrome, Firefox, Edge, Brave, Arc, Opera, Vivaldi, Chromium). Ordinary rules can't name them; site blocking already covers websites inside them. A Go day is the one exception: it can carry the special "Web browsers" target, which matches any app whose Info.plist claims the `http` or `https` URL scheme.

Choosing a refused app shows the reason (`AppTarget.ChoiceProblem`). The engine also drops refused targets, so a stored rule can't reach them.

## Closing apps

`AppSweep` decides; `AppEnforcer` acts.

1. **An app already open when its block begins** gets SIGTERM, like choosing Quit, so it can save. If it is still open 60 seconds later, it gets SIGKILL.
2. **An app opened during a block** gets SIGKILL at once.
3. **During allowed hours** nothing is closed.
4. Apps that relaunch themselves are closed again each time. Shield never edits the app or the user's login items.

## Components

**Decisions (pure):** `Kairos/AppBlocking.swift`

- `AppMatcher`: matching
- `AppBlockSafety`: the never-blockable lists
- `AppRuleChangeClassifier`: a new rule, or the same or more targets with the same or stricter hours, is immediate; anything else waits at least 24 hours
- `AppBlockEngine`: which targets are blocked now; every committed target when state can't be verified
- `AppSweep`: the ask-then-force sequence

**Apps on ordinary rules.** `DomainRestriction.apps` and `DailySchedule.apps` carry app targets, so app blocks reuse everything website blocks already have:

- stricter changes are immediate, looser ones wait at least 24 hours
- release requests and the 72-hour correction window for new permanent blocks
- categories
- the exact-match confirmation of a request

Encoding notes:

- Rules without apps keep their exact earlier encoding. `apps` is written only when present.
- A document holding apps is written as at least schema 3 (`BackendDocument.version`), so an older service refuses it rather than silently dropping its apps.
- The service's integrity check compares committed apps as well as sites.

**`AppEnforcer`** (`Kairos/AppEnforcement.swift`):

- looks only at the configured user's processes, never its own process or launchd
- identifies each process by its running code signature, re-read when the PID or executable changes (so `sh -c 'exec Game'` is caught)
- sends SIGTERM, then SIGKILL after 60 seconds; an app opened during a block gets SIGKILL at once
- re-checks that a PID is still the same process before signalling it

**Installed service** (`AuthorityService/InstalledAppEnforcement.swift`):

- Hosts and apps are enforced on every 2-second maintenance pass.
- Apps are enforced even if the hosts step fails.
- When the state can't be verified, every committed app is closed (fail closed).

**UI.** Block editors have an Add App… button. It opens the standard Open panel and reads the chosen app's signature. It refuses Mac essentials, browsers and Shield itself, with a reason, and shows the app's own icon.

**Trying it in a development build.** Launched with `SHIELD_PREVIEW_APP_BLOCKING=1`, the development build closes the apps its simulated policy blocks, for the current user only. It is off otherwise, and never active in UI Review or a release build.

## Testing

- `ShieldTests/AppBlockingTests.swift`
- `ShieldTests/AppBlockingPolicyTests.swift`: includes a real SIGTERM to a child process, and the real signatures of Chess, Finder, System Settings and Safari.
- `ShieldUITests/ShieldAppBlockingFlowTests.swift`: New Block → Add App → Chess → create → open Chess → Shield closes it. Uses the development preview enforcer.
- On an installed build, check that a blocked app closes within a few seconds of opening, and that an already-open app is asked to quit first.
