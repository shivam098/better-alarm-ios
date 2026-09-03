# Alarmy — an alarm you cannot ignore

An iOS alarm app built around one idea: **pressing Stop should not be enough.**
The alarm is only truly over once you have proved you are awake by completing a
mission — solving maths, retyping a phrase, shaking the phone, walking, doing
squats, or photographing a place in your home that you have to get out of bed to
reach.

Every mission is free. There is no paywall on waking up.

> **Status: unbuilt.** This repository was authored without access to a Mac, so
> nothing here has ever been through the Swift compiler. The pure-logic layer
> (`AlarmyCore`) is fully unit-tested and `swift test` is expected to pass; the
> UIKit/SwiftUI/AlarmKit layer is expected to need a small number of signature
> fixes on the first build. See [First build](#first-build-what-to-expect).

---

## Table of contents

- [Why this app is architected the way it is](#why-this-app-is-architected-the-way-it-is)
- [Requirements](#requirements)
- [Getting started on a Mac](#getting-started-on-a-mac)
- [Running the tests (do this first)](#running-the-tests-do-this-first)
- [Building and running the app](#building-and-running-the-app)
- [The AlarmKit entitlement](#the-alarmkit-entitlement)
- [First build: what to expect](#first-build-what-to-expect)
- [Repository layout](#repository-layout)
- [The missions](#the-missions)
- [Testing on a real device](#testing-on-a-real-device)
- [Privacy](#privacy)
- [Documentation](#documentation)
- [Licence](#licence)

---

## Why this app is architected the way it is

There is one platform fact that shapes everything else in this repository:

**AlarmKit always draws a Stop button on the system alarm alert, and a
third-party app cannot remove it, rename it, or make it conditional.**

That single constraint kills the naive design. If the only thing keeping you
awake is a mission screen inside the app, the user simply hits Stop on the
system alert, never launches the app, and goes back to sleep. Worse, iOS gives
no guaranteed background execution after that Stop, so the app cannot react and
re-arm itself.

The answer is **Mission Guard**:

> When an alarm is created, Alarmy does not schedule one system alarm. It
> schedules a *chain* — the alarm itself, plus a series of follow-up system
> alarms at +1, +3, +6, +10, +15 minutes and beyond. Pressing Stop dismisses
> only the alert in front of you; the rest of the chain is untouched and the
> next one fires a minute later. **Completing a mission is the only thing that
> cancels the chain.**

Pre-scheduling is not an optimisation, it is the whole trick. The chain has to
exist on the system's timers *before* the user is asleep, because afterwards the
app may never get to run again.

Everything else follows from this:

| Decision | Reason |
| --- | --- |
| `AlarmyCore` has no Apple-framework imports | So the rules that make the alarm trustworthy can be tested in seconds on any machine, with no simulator and no signing. |
| Only one file imports AlarmKit | AlarmKit is new and its signatures are still moving. All the drift risk is quarantined in `AlarmKitScheduler.swift`. |
| The state machine is a pure reducer | Given a state and an event it returns a new state and a list of effects. It cannot accidentally forget to cancel a chain, because the tests enumerate every transition. |
| System alarm IDs are derived, not random | The ID is a hash of the occurrence key, so re-scheduling the same occurrence after a reboot replaces it instead of duplicating it. |
| Watchdog alarms cannot be snoozed | Snoozing a watchdog would reopen exactly the loophole the watchdog exists to close. |

The five invariants the test suite enforces:

1. Pressing Stop is **not** completing the alarm.
2. Failing a mission never dismisses the alarm.
3. Only mission completion cancels the watchdog chain.
4. Backgrounding the app mid-mission preserves progress; it does not reward you.
5. An incoming call can never cause a missed alarm.

---

## Requirements

| | |
| --- | --- |
| **macOS** | Sequoia 15 or later (Tahoe 26 recommended) |
| **Xcode** | **26.0 or later** — AlarmKit does not exist in earlier SDKs |
| **Device** | A physical iPhone running **iOS 26.0 or later** |
| **Apple Developer account** | Required — the App Group and the AlarmKit entitlement both need one |
| **XcodeGen** | `brew install xcodegen` — the `.xcodeproj` is generated, not committed |

> **The simulator is not enough.** AlarmKit alarms, Live Activities, Core Motion
> and the camera missions all need real hardware. You can run the app in the
> simulator to look at the UI, but you cannot test an alarm there.

---

## Getting started on a Mac

```bash
# 1. Clone
git clone https://github.com/shivam098/alarmy-ios.git
cd alarmy-ios

# 2. Install the project generator
brew install xcodegen

# 3. Verify the logic before you build anything
make test

# 4. Generate the Xcode project and open it
make open
```

`make open` runs `xcodegen generate` and then opens `Alarmy.xcodeproj`. The
project file is intentionally **not** committed — `project.yml` is the source of
truth, which keeps diffs readable and avoids the merge conflicts that
`project.pbxproj` is famous for.

---

## Running the tests (do this first)

```bash
make test
# equivalently:
cd AlarmyCore && swift test
```

This is the most useful command in the repository and the one you should run
before anything else. It needs **no Xcode project, no device, no simulator and
no signing** — `AlarmyCore` is a plain Swift package.

What it verifies:

| Test file | What it proves |
| --- | --- |
| `AlarmScheduleCalculatorTests` | Next-occurrence maths, repeat days, skip-next, and that a 02:30 alarm still fires correctly on the day the clocks change. |
| `AlarmStateMachineTests` | All five invariants above, plus snooze limits and interruption handling. |
| `MissionGuardTests` | The watchdog chain is planned correctly, survives Stop, and is cancelled by — and only by — mission completion. |
| `OverlapAndMissedWindowTests` | Two alarms landing on the same minute, and what counts as "missed" versus "still ringing". |
| `MissionGeneratorTests` | Every generator is reproducible from a seed, respects difficulty, never emits an unsolvable challenge, and does not repeat recent challenges. |
| `AntiCheatTests` | Shaking detection rejects mechanical/periodic motion; step counting rejects pre-banked steps; squat counting rejects partial reps and bouncing. |
| `StatisticsTests` | Streaks, grace days, and wake-time aggregates. |

If this suite passes, the part of the app that determines whether you actually
get out of bed is correct. The rest is presentation.

---

## Building and running the app

Once `make test` is green:

1. **Set your team.** Open `project.yml` and replace the `DEVELOPMENT_TEAM`
   value with your 10-character Apple Developer Team ID (Xcode → Settings →
   Accounts → your account → Team ID). Alternatively set it once in Xcode's
   *Signing & Capabilities* tab after generating.

2. **Choose a bundle identifier.** The default prefix is `com.alarmy`. If you
   do not own that, search-and-replace it in `project.yml` — three targets use
   it:

   | Target | Identifier |
   | --- | --- |
   | App | `com.alarmy.app` |
   | Widget extension | `com.alarmy.app.widget` |
   | App Group | `group.com.alarmy.app` |

   The App Group string also appears in
   `Alarmy/Resources/Alarmy.entitlements`,
   `AlarmyWidget/AlarmyWidget.entitlements` and
   `Alarmy/Persistence/AlarmStore.swift`. All three must match, or the widget
   and the App Intents will silently read an empty alarm store.

3. **Create the App Group** in the Apple Developer portal (Certificates,
   Identifiers & Profiles → Identifiers → App Groups) and attach it to both
   bundle IDs.

4. **Regenerate and build:**

   ```bash
   make project
   open Alarmy.xcodeproj
   ```

   Select the `Alarmy` scheme, choose your connected iPhone, and run.

---

## The AlarmKit entitlement

AlarmKit needs **two separate permissions**, and it is easy to confuse them:

**1. The user's permission** — requested at runtime by the app, backed by the
`NSAlarmKitUsageDescription` string in `Info.plist`. This already works; the
app asks for it on first launch and the Settings screen shows the current
status.

**2. Apple's permission** — a managed entitlement your *team* must be granted.
Alarms that ring through Silent Mode and Focus are a privileged capability, so
Apple reviews who gets it.

For development you can usually run on a device without step 2, but for
TestFlight and the App Store you will need it. To request it, use the
[Apple Developer entitlement request form](https://developer.apple.com/contact/request/)
and describe the alarm use case.

When it is granted, uncomment this block in
`Alarmy/Resources/Alarmy.entitlements`:

```xml
<key>com.apple.developer.alarmkit</key>
<true/>
```

> Do **not** uncomment it beforehand. Requesting an entitlement your profile
> does not carry makes code signing fail with a confusing error.

Also note `NSSupportsAlarmInterruptions` in `Info.plist`. That is the key that
stops a phone call silently swallowing your alarm — without it, an incoming call
at 06:59 can mean you never hear 07:00.

### What Alarmy deliberately does *not* use

**Critical Alerts.** It is the obvious tool for "an alert that ignores Silent
Mode", and Apple routinely refuses it for alarm apps — it is reserved for
medical and public-safety alerts. Designing around an entitlement you will not
be granted is how alarm apps ship broken. AlarmKit provides the same
break-through behaviour through a supported route, so Alarmy uses that and
treats Critical Alerts as a non-goal.

---

## First build: what to expect

**Be honest with yourself about this section before you file a bug.** Every
Swift file here was written without a compiler. The logic has been traced by
hand and the tests were written against the real source, but no build has ever
run.

Expectations:

- **`AlarmyCore` should compile and test cleanly.** It is plain Foundation
  Swift with no platform APIs, and it is the part that was verified most
  carefully.
- **The app layer may need small fixes.** Most likely candidates, in order:

  1. **`Alarmy/Scheduling/AlarmKitScheduler.swift`** — this is the only file
     that imports AlarmKit and therefore the only place API drift can bite.
     `AlarmPresentation.Alert`'s initialiser changed between iOS 26.0 and
     26.1; the `makeAlert` function carries a comment marking the exact line to
     adjust. If the build breaks, look here first.
  2. **Strict-concurrency warnings.** `project.yml` deliberately sets
     `SWIFT_VERSION: "5.0"`, so actor-isolation and `Sendable` complaints
     arrive as warnings rather than errors. Do not switch to Swift 6 language
     mode until the app builds and runs; you will be fixing two problems at once.
  3. **Missing sound assets.** `Alarmy/Resources/Sounds/` is empty by design —
     see [the note in that folder](Alarmy/Resources/Sounds/README.md). The
     scheduler already falls back to the system default tone, so this is not
     fatal.

If you hit something, the fix is almost always local. The architecture keeps
platform APIs at the edges precisely so a compiler surprise cannot force a
redesign.

---

## Repository layout

```
alarmy-ios/
├── AlarmyCore/                  Pure Swift package — no Apple frameworks
│   └── Sources/AlarmyCore/
│       ├── Models/              Alarm, MissionConfig, Weekday, AlarmOccurrence
│       ├── Scheduling/          Next-fire maths, Mission Guard, overlap rules
│       ├── State/               The alarm state machine and wake statistics
│       ├── Missions/            Challenge generators and anti-cheat validators
│       └── Support/             Clock abstraction, seeded RNG
│   └── Tests/                   7 test files — the real specification
│
├── Alarmy/                      The iOS app
│   ├── App/                     Entry point, root view, scene-phase wiring
│   ├── Scheduling/              AlarmKit isolation, request building, coordinator
│   ├── Persistence/             App Group JSON store, challenge history
│   ├── Sensors/                 Permissions, motion, camera, interruptions
│   ├── Views/                   SwiftUI screens
│   └── Resources/               Info.plist, entitlements, sounds
│
├── AlarmyWidget/                Live Activity for the ringing alarm
├── docs/                        PRD and architecture notes
└── project.yml                  XcodeGen manifest — the project's source of truth
```

Two files are worth reading before the rest:

- **`AlarmyCore/Sources/AlarmyCore/State/AlarmStateMachine.swift`** — the rules
  of the product, expressed as a pure function.
- **`Alarmy/Views/MissionRunnerView.swift`** — the ringing screen. Its three
  omissions are the point: there is no dismiss button, no navigation away, and
  no way to reveal the answer.

---

## The missions

All eleven are free. Each has three difficulty levels and a configurable number
of rounds.

| Mission | Type | Needs |
| --- | --- | --- |
| Maths | Mental | — |
| Missing symbol | Mental | — |
| Memory sequence | Mental | — |
| Typing | Mental | — |
| Shake | Physical | Motion sensors |
| Steps | Physical | Motion & Fitness permission |
| Squats | Physical | Camera |
| Photo | Physical | Camera |
| Barcode | Physical | Camera |
| Hold still | Physical | Motion sensors |
| Wake-up check | Timed | — |

The mission picker shows each mission's difficulty and the permissions it needs
*before* you select it, so nobody discovers at 06:00 that their chosen mission
needs a camera permission they denied.

**Anti-cheat is layered, not a single check:**

- *Steps* baseline on the first reading, so steps banked before the alarm do not
  count; the rate and the cadence are then cross-checked against each other.
- *Shake* requires a genuine direction reversal, a refractory period between
  counted shakes, and corroborating rotation — and rejects motion whose timing
  is too regular to be human.
- *Squats* require full range of motion and reject bouncing.

---

## Testing on a real device

Testing an alarm app is inherently awkward. Some practical advice:

- Set an alarm two minutes out, lock the phone, and put it face down. Do not
  keep the app in the foreground — that is not the case that matters.
- **Test the Stop button deliberately.** Press Stop and go back to sleep. If
  the app works, another alarm arrives about a minute later. That is Mission
  Guard, and it is the single most important behaviour to confirm.
- **Test with the app force-quit.** Swipe it away from the app switcher, then
  wait for the alarm. It must still ring: the alarms live on the system's
  timers, not in your process.
- **Test with Silent Mode on and a Focus active.** Both should be broken
  through.
- **Test an incoming call.** Have someone call you a minute before the alarm.
  The alarm must still arrive.
- **Reboot the phone** with an alarm pending, and confirm it still fires.
- Watch the logs with Console.app or:

  ```bash
  xcrun devicectl device info details    # find your device
  log stream --predicate 'subsystem == "com.alarmy.app"' --level debug
  ```

The Settings → Reliability screen inside the app lists anything that could stop
an alarm working — a missing permission, Low Power Mode, a denied notification
setting — in plain language.

---

## Privacy

Alarmy has no account, no server, and no analytics.

- Alarms, history and statistics live in the App Group container on the device.
- Camera frames for the squat and photo missions are processed **on device** and
  are never written to disk or transmitted. The photo mission stores a
  perceptual hash of your reference photo, not the photo itself.
- Motion data is read only while a mission is running.

---

## Documentation

| Document | Contents |
| --- | --- |
| [`docs/PRD.md`](docs/PRD.md) | The full product requirements document: goals, personas, all 11 missions, a 35-row edge-case matrix, the data model, and traceability back to the original SRS. |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | How the layers fit together, why the seams are where they are, and the sequence of an alarm firing. |

If you only read one thing, read §6.2 of the PRD — the Mission Guard rationale.
It explains why this app is built the way it is rather than the obvious way.

---

## Licence

MIT. See [LICENSE](LICENSE).
