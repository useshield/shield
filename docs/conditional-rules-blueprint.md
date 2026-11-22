# Shield: conditional rules (place, time, Wi-Fi, study) — design

This document covers blocks that depend on where the Mac is, the time of day, nearby Wi-Fi, or study time. It describes:

- the **conditional rules engine** (§1–§2), which the authority stores and evaluates (§7);
- **sensing location** (§4, §6), which only the signed app does;
- the **app side** (§8): places, blocks limited to a place, and Go days.

The app does not yet offer a way to create general conditional rules. It uses places for blocks limited to a place and for Go days. The engine's rules are fully wired into the authority and tested, so a UI can be added on top.

## 1. The model

A **rule** = **domains** + **effect** (`block` or `allow`) + **conditions**. A rule applies when every one of its conditions holds.

| Condition | Meaning |
|---|---|
| `timeWindow(start, end, weekdays)` | Local minutes. Wraps past midnight, and the part after midnight belongs to the previous day's weekday. |
| `atPlace(place, dwell)` | At an enrolled place, for at least `dwell` minutes for exceptions. |
| `notAtPlace(place)` | Away from a place. |
| `arrivedToday(place, minutes)` | Verified time spent at the place today, reset at local midnight. |
| `studiedToday(minutes)` | Study minutes completed today in Shield's library player. |

**Formats this covers:**

- **Blocked until I arrive:** `block` + `arrivedToday(library, 15)`. Sites stay blocked every day until you've spent 15 verified minutes at the library.
- **Only at a place:** the base schedule blocks the site, plus `allow` + `atPlace(library, 10)` + `timeWindow(9–18)`.
- **Stricter somewhere:** `block` + `atPlace(home)` + `timeWindow(22–6)`.
- **Earn it:** `allow` + `studiedToday(45)`.
- **Combinations:** for example, "a video site at the library, 2–8 PM, after 30 minutes of study".

## 2. Safety rules

Each rule has a unit test.

1. **Uncertainty always means more blocking.** Unknown or missing evidence makes a `block` condition hold and an `allow` condition fail.
2. **Asymmetric evidence.**
   - Making things stricter needs any one signal: the connected Wi-Fi matches, two visible access points match, or a location fix touches the fence.
   - Loosening needs all of these:
     - a fresh fix (≤ 120 s), not simulated, at full accuracy, with accuracy ≤ min(0.6 × radius, 80 m)
     - the **whole error circle inside** the fence
     - a matching Wi-Fi signal (the connected access point, or ≥ 3 visible ones)
     - **no home-Wi-Fi veto**
     - no sleep since the last sample
     - the required continuous dwell
3. **24-hour precommitment.** An `allow` rule does nothing until it has existed for 24 hours. You decide on exceptions while calm, never in the moment.
4. **Block beats allow.** An active `block` rule always wins over an `allow` rule for the same site.
5. **Protected blocks can never be opened.** Only domains blocked solely by a daily schedule can be relaxed. Permanent, until-released and timed blocks are added back last, so no rule can open them.
6. **Allow rules only subtract from relaxable base blocks.** They never edit the stored daily schedule windows, so allowed and blocked hours can't be swapped by a rule.
7. **Changes are classified** (`RuleChangeClassifier`):
   - Adding a block, widening a block's sites, removing an allow, narrowing an allow's sites, or adding a condition to an allow: **immediate**.
   - Everything else: **at least a 24-hour delay**.
8. **Presence lives in memory only.** A restart or a gap of more than 90 s resets dwell. Daily dwell and study totals reset at local midnight.

## 3. Components

| Piece | File | Notes |
|---|---|---|
| Engine, gates, dwell tracker, change classifiers, plain-language summaries | `Kairos/ConditionalRules.swift` | Pure. Tests in `ShieldTests/ConditionalRulesTests.swift`. |
| Recorded presence (`PresenceSnapshot`), report gate, place limits, place-change classifier | `Kairos/ConditionalRules.swift` | Pure. See §6. |
| Go day arrival (`GoDayArrival`, `GoDayConfirmation`) | `Kairos/ConditionalRules.swift` | Pure. See §8. |
| Location sensor in the app | `Kairos/LocationSensor.swift` | See §4. |
| Per-user fallback sensor | `ShieldLocationHelper/main.swift` | Not built into any target. See §4.2. |
| Authority integration | `PolicyModels`, `PolicyServices`, `FixtureBackend`, `FixtureBackendXPC` (+ client), `PolicySubmission` | See §7. Tests in `ShieldTests/ConditionalAuthorityTests.swift`. |

## 4. Sensing location

The app senses; the service judges. The app sends evidence only. It holds no policy authority and can't change any block.

### 4.1 The sensor in the app

`Kairos/LocationSensor.swift`:

- Core Location (best accuracy) plus CoreWLAN.
- Wi-Fi access points become keyed HMAC tags (`WiFiTagger`). The key is 32 random bytes in a file only the user can read (mode 0600). An existing key is never replaced, because a new key would orphan every saved place's Wi-Fi. Raw BSSIDs never leave the file.
- The first report after sleep is marked, and never counts as a known location.
- Nothing starts until the user adds a place or turns location on, so no permission prompt appears unasked. On launch it resumes only if the user already answered the prompt.

### 4.2 The fallback helper

`ShieldLocationHelper/main.swift` is a small per-user helper that samples Core Location and Wi-Fi once a minute and writes evidence as JSON lines, with HMAC tags only. It exists because it is not confirmed that a per-user helper can reliably hold the Location privilege on macOS (§6). It is not built into any target. The app is the sensor.

### 4.3 Presence reports

`PresenceReportBuilder`:

- the sequence number comes from `CLOCK_MONOTONIC_RAW`, so it rises across app restarts within one boot, as the service's gate requires
- awake time comes from `CLOCK_UPTIME_RAW`
- the boot session comes from `kern.bootsessionuuid`

Reports go over XPC to the service (`reportPresence`), or to the in-process backend in a development build. The service checks every report with `PresenceReportGate` (§6).

### 4.4 Study minutes

`studiedToday` is only as honest as the player's measurement. There is no verified study-minute reporter yet, so the recorded study total is always unknown and `studiedToday` resolves strict: a `block` holds and an `allow` fails.

A reporter needs a rule for what counts. Playing a video muted in the background shouldn't. For example: the player window is frontmost and playback is advancing.

## 5. Limits

- Without reports, location is unknown and place rules turn strict. If the service itself isn't running, gap evidence (`Kairos/ServiceGapEvidence.swift`) records the gap; it can't prevent it.
- Wi-Fi tags can be replayed by someone with radio equipment. The home veto and dwell rules raise the cost but don't make it impossible.
- macOS stops location updates while the Mac sleeps. Waking resets dwell, which is fail-closed.
- Network names can be set to anything, so Wi-Fi alone never proves presence.
- `studiedToday` is only as honest as the player's measurement (§4.4).

## 6. Location on macOS, and what the service records

**Platform facts that shape the design** (from Apple documentation and Apple staff on the developer forums):

- **Only the app can sense location.** The root service can't hold the Location privilege. Whether a per-user helper reliably can is unconfirmed, so the sensor lives in the signed app itself, with `ShieldLocationHelper` as a fallback.
- **On a Mac, location comes from Wi-Fi.** "While using" and "Always" permission behave the same.
- **Area monitoring works only while the app runs and the Mac is awake.** It is capped at 20 areas and never relaunches the app. Quitting Shield therefore means location is unknown, which turns every place rule strict.
- **Reading the Wi-Fi network name needs Location permission too** (macOS 14 and later). Wi-Fi only ever makes things stricter or vetoes. It is never proof by itself.
- **Adding the Location keys and entitlement changes the app's code signature.** The installed service checks the app's signature, so app and service ship together.

**What the service keeps and checks (pure code in `Kairos/ConditionalRules.swift`):**

1. **`PresenceSnapshot`, the record the service keeps.** It holds per-place verdicts (any sign of being there; exception-grade proof; continuous dwell; time there today) plus study minutes. It never holds coordinates or Wi-Fi tags. Rules are evaluated from this record, so the service's integrity check (`verifyCommittedDocument`, which re-runs evaluation at commit time and needs an exact match) can replay a committed state.
   - A record ages from its fix, not from when it arrived. Verdicts older than 120 s are unknown, so place rules turn strict.
   - Time earned at a place counts only on the day it was earned.
2. **`PresenceReportGate`.** It checks each report from the app:
   - the same boot session as the service
   - the sequence number must increase
   - awake time must never run backwards
   - observed within 30 s of now
   - sane coordinates and at most 64 Wi-Fi tags

   A refused report leaves location unknown, which means strict. The XPC connection already checks the app's signature and user, so the report itself carries no signature: any key the app held, the same user could read.
3. **`RulePlaceValidator`.**
   - Limits: radius 100 m to 2 km, at most 20 places (Apple's area cap) and 50 rules, at most 8 conditions and 100 domains per rule, unique IDs, valid coordinates.
   - Exactly one home whenever an exception uses a place, because home is the veto.
   - No rule may name a place that doesn't exist.
4. **`PlaceChangeClassifier`.**
   - Adding a place is immediate, since it does nothing until a rule uses it. Renaming is immediate.
   - Moving, resizing, retagging or deleting a place always waits 24 hours. "At" and "away from" rules pull in opposite directions, so any geometry change loosens one of them.

## 7. Authority integration

| Piece | What it does |
|---|---|
| Stored state | `BackendDocument` gains `conditions` (places, rules, the last accepted `PresenceSnapshot`). It is written as at least **schema 4** only while places, rules, their pending changes or place-limited blocks exist. Without them the document keeps a lower version, so an older service can still read it, and refuses exactly the documents it would mis-read. |
| Authority file | `AuthorityState` gains `conditions` (places, rules, presence, and which rule opened or tightened which domain). **Schema 2**, again only when conditions exist. A reader that accepts only schema 1 shows "unsupported schema" instead of mis-reading. A schema-1 state that carries conditions is refused. A conditional block appears with the policy owner `conditional` and id `rule:<id>`. |
| Commands | `addPlace`, `replacePlace`, `removePlace`, `addConditionalRule`, `replaceConditionalRule`, `removeConditionalRule`. Each is classified by `PlaceChangeClassifier` / `RuleChangeClassifier`. Stronger changes apply at once and must carry no date. Weaker ones must carry a date at least 24 hours away and wait as a `PendingPolicyRelease` under the owner id `place:<id>` or `rule:<id>`, carrying the replacement (nil means remove). `cancelPendingRelease` works on them unchanged. One pending change per place or rule. |
| Dating | The service sets each rule's `committedAt` itself, never the client. A new exception waits 24 hours as a pending change and lands already past its precommitment. A stronger edit keeps the original date. |
| Validation | `RulePlaceValidator` must pass **now and after every pending change lands**, so a later landing can't leave a dangling place. Restrictions and schedules may not use `place:` / `rule:` ids or the `conditional` owner. |
| Evaluation | `UnifiedPolicyEngine.evaluate(…, conditions:)` runs the base (restrictions ∪ schedules), then `ConditionalRuleEngine.evaluate`. **Only domains blocked solely by a daily schedule can be opened.** Permanent, until-released and timed blocks are never relaxable. Opened domains are removed from the effective `recurring` entry; the stored `DailySchedule` values are never edited. Apps in a schedule stay blocked: conditional rules open sites only. Rule transitions (window edges, an exception's 24 hours, the record going stale, midnight) feed `nextTransition`. |
| `reportPresence` | Fixture backend and XPC (`reportPresence(_:reply:)`, client `reportPresence(_:)`). The report goes through `PresenceReportGate` (boot session = `kern.bootsessionuuid`), then the in-memory `PresenceTracker` (`PresenceSession`, one per service run, never persisted). A new `PresenceSnapshot` is committed only when the effective blocks change, or when places are in use and a new known record is at least 30 s newer than the stored one. Records expire at 120 s, so this keeps continued presence from lapsing between heartbeats. A refused report throws, resets dwell continuity, and stores nothing; the old record ages out (strict). |
| Restart | When the service starts, it marks any stored location as unknown (`forgetPresence`). A new run has no gate or dwell state for an old record, so place blocks hold until it accepts a fresh report. |
| Replay | `verifyCommittedDocument` evaluates at the authority's `generatedAt` with the **stored** record, so its exact-match check holds however old the record is. Maintenance (every 2 s) compares owners **and domains**, so a record going stale re-blocks within seconds. |
| Moves | When a moved, resized or retagged place lands, its recorded verdict is dropped (strict until a new report). |
| Confirmation | `PendingPolicySubmission.isConfirmed` recognizes each new command: immediate ones by content in the committed state (rules by content, not date), delayed ones by the exact pending change. |
| Build lists | `Kairos/ConditionalRules.swift` is in every `swiftc` file list that compiles the policy model (root service, fixture service and CLI, worker, egress broker, CI workflow). |

## 8. App side

The app only senses and asks. The service judges every report, keeps verdicts rather than coordinates, classifies each change (stricter now, looser after 24 hours) and decides every block. An older service can't decode place commands, so Places stays hidden until the service says it supports them.

**Places page** (`Kairos/PlacesView.swift`, `Kairos/PlaceEditor.swift`):

- A map of your places, a list, and one page per place showing what's blocked there. States come from the service's record, never the sensor's guess.
- **Add a place** by searching or clicking the map, sizing the circle (100 m to 1 km) and naming it. "Use My Location" drops the pin where the Mac is and, when the reading is precise, saves the Wi-Fi seen there, so Shield can later tell you are really at the place. A place pinned from your own location is at least 200 m, because the reading itself may be 100 m off.
- **Rename** applies at once. **Remove** waits 24 hours, and only once no block uses the place.

**Blocks limited to a place** (`DomainRestriction.placeID`, encoded only when set):

- New Block offers a place option with a **Where** picker. Websites, apps and categories work exactly as in any other block.
- Such a block applies while the service's record says the Mac is at that place (any one signal is enough), and whenever location is unknown or stale (strict).
- Only "until released" blocks may name a place, only an existing place that isn't being changed or removed, and a place used by a block can't be removed. Releasing one takes 24 hours, as for any such block. Apps in a place block are closed like any other.

**Go days** (`DomainRestriction.goDay`, `GoDayGate`): a timed block that lifts for the rest of its day once the service sees the Mac arrive at one of the day's places.

- A day records where it began (a fix, or at least two visible Wi-Fi tags), so arriving can't happen without leaving. It holds up to 5 places, each 100 m to 1 km.
- Arrival needs two qualifying readings at least 20 s apart in awake time, from the same service run. A qualifying reading is a fresh (≤ 60 s), precise (≤ 100 m), real fix whose centre is inside a place, not just after sleep, and nothing that looks like where the day began.
- A Go day you already reached stays lifted even when the service can't verify its state.

**Reporting and permission:**

- Location is used only while a block or rule depends on a place, or a Go day is waiting to be reached. A place saved for later doesn't keep Shield checking where the Mac is.
- Reports are sent on a change (at most every 10 s) and as a heartbeat about once a minute; every 20 s while a Go day is waiting. The service keeps a verdict for 120 s, so a quit or sleeping Shield leaves location unknown, which is strict.
- Before macOS's own Location prompt, Shield shows one screen saying why it wants it.
- `NSLocationUsageDescription` and `NSLocationWhenInUseUsageDescription` are set on the app. The release packagers sign the app with `Configuration/ShieldLocation.entitlements`, which includes `com.apple.security.personal-information.location`.

**Development preview.** `bash scripts/run_location_preview.sh` builds and opens the development app with a simulated policy. Nothing in it protects the Mac, and the Location prompt names "Shield Development".

## 9. Testing

- `ShieldTests/ConditionalRulesTests.swift`: the engine, gates, dwell and classifiers.
- `ShieldTests/ConditionalAuthorityTests.swift`: schema versions, change classification, refused commands, protected blocks never opening, dwell and replay, restart forgetting presence, the XPC wire.
- `ShieldTests/LocationRulesAppTests.swift`: reports, Wi-Fi tags, status text, and place blocks through the fixture authority with reports built exactly as the app builds them.
- `ShieldTests/LocationAuditFixTests.swift`: record age, the first report after sleep, enrollment precision, Wi-Fi key preservation.
- `ShieldTests/LocationRulesSnapshotTests.swift`: offscreen captures, which also assert Core Location never starts.
- `ShieldUITests/ShieldLocationFlowTests.swift` and `ShieldUITests/ShieldGoDayFlowTests.swift`: the place and Go day flows in the development build.
- On a real Mac, it is worth measuring how accurate location is at your own places before relying on allow rules. Wi-Fi-based fixes may be too coarse for the exception thresholds in §2.
