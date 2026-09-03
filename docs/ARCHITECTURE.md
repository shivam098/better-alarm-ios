# Architecture

## The constraint everything is built around

AlarmKit renders the system alarm alert. It always includes a Stop button, and a
third-party app cannot remove it, rename it, or gate it behind a condition.

That is fatal to the obvious design, in which the app owns a mission screen and
the alarm ends when the mission is passed. In practice the user never reaches
the mission screen: they press Stop on the system alert and go back to sleep.
And because iOS grants no guaranteed background execution after a Stop, the app
cannot notice and re-arm itself.

## Mission Guard

When an alarm is created — not when it fires — Alarmy schedules a chain of
system alarms:

```
07:00  the alarm
07:01  watchdog 1
07:03  watchdog 2
07:06  watchdog 3      ← escalation begins here
07:10  watchdog 4
07:15  watchdog 5
...
```

`WatchdogPlanner` computes the chain from offsets `[1, 3, 6, 10, 15, 20, 25, 30,
40, 50, 60]` minutes, trimmed to a `SchedulingBudget` (default `maxEntries: 6`,
`escalateFromIndex: 3`).

The rules:

- **Stop preserves the chain.** `AlarmStateMachine` treats `.stopPressed` as
  "the user silenced this particular alert", nothing more.
- **Only `.missionCompleted` cancels it.**
- **Watchdogs cannot be snoozed** (`allowSnooze: false`). A snoozeable watchdog
  is not a watchdog.

Pre-scheduling is mandatory rather than merely convenient. The chain must exist
on the system's timers before the user falls asleep, because afterwards the app
may never get another chance to run.

## Layers

```
┌────────────────────────────────────────────────────────────┐
│ SwiftUI views                                              │
│   AlarmListView · AlarmEditorView · MissionRunnerView …     │
└───────────────────────────┬────────────────────────────────┘
                            │ observes / sends events
┌───────────────────────────▼────────────────────────────────┐
│ AlarmCoordinator            @MainActor, single instance    │
│   owns the ringing session, runs effects, reconciles state │
└───────┬───────────────────────────────────┬────────────────┘
        │ decisions                         │ side effects
┌───────▼──────────────────┐   ┌────────────▼────────────────┐
│ AlarmyCore               │   │ SystemAlarmScheduling        │
│   pure Swift, no Apple   │   │   protocol — no AlarmKit      │
│   frameworks, all tested │   └────────────┬────────────────┘
│                          │                │
│   AlarmStateMachine      │   ┌────────────▼────────────────┐
│   WatchdogPlanner        │   │ AlarmKitScheduler            │
│   AlarmScheduleCalculator│   │   the ONLY AlarmKit import    │
│   mission generators     │   └─────────────────────────────┘
│   anti-cheat validators  │
└──────────────────────────┘
```

Two seams matter.

**`AlarmyCore` imports nothing but Foundation.** All the reasoning that decides
whether the user gets out of bed lives there, which means it is testable with
`swift test` in a couple of seconds — no simulator, no signing, no device. It is
the only part of this repository whose correctness can be demonstrated rather
than asserted.

**`SystemAlarmScheduling` is an AlarmKit-free protocol.** The coordinator talks
to that protocol; `AlarmKitScheduler` is the one implementation that imports the
framework, and `PreviewAlarmScheduler` is the one used by SwiftUI previews. When
AlarmKit's signatures shift between iOS releases — and they already have,
between 26.0 and 26.1 — exactly one file needs changing.

## The state machine

`AlarmStateMachine` is a pure reducer:

```swift
func handle(_ event: AlarmEvent, at now: Date) -> (AlarmState, [AlarmEffect])
```

It performs no I/O and holds no references to system frameworks. The coordinator
executes the returned effects; it contains no rules of its own. Any rule that
lives in the coordinator is a rule that cannot be tested, so none do.

Invariants encoded in `AlarmStateMachineTests` and `MissionGuardTests`:

1. Stop is not completion.
2. A failed mission never dismisses the alarm.
3. Only mission completion cancels the watchdog chain.
4. Backgrounding mid-mission preserves progress without rewarding it.
5. An incoming call cannot produce a missed alarm.

## Identity and idempotency

Every occurrence has a stable key:

```
<alarmID>                 the alarm itself
<alarmID>#wd3             the third watchdog
<alarmID>#snooze2         the second snooze
```

`SystemAlarmRequest.identifier(for:)` hashes that key with FNV-1a into a
deterministic UUID. Consequences:

- Re-scheduling the same occurrence **replaces** it rather than duplicating it,
  so reconciliation after a reboot, a crash, or a sync merge is naturally safe
  to run repeatedly.
- `AlarmStore.rootKey(of:)` splits on the first `#`, so an entire chain can be
  found and cancelled atomically the moment a mission is passed.

`AlarmCoordinator.reconcile()` is where this pays off: it compares what *should*
be scheduled against what AlarmKit reports is scheduled, and converges. It can be
called at launch, on foreground, or after any state change, as often as you like.

## Time

All next-fire computation goes through `Calendar.nextDate(after:matching:...)`
with `matchingPolicy: .nextTime` and `repeatedTimePolicy: .first`. There is no
arithmetic on time intervals to find the next 07:00.

This is deliberate. Manual date maths is where alarm apps break twice a year: on
the spring-forward day a 02:30 alarm refers to a wall-clock time that does not
exist, and on the autumn day it refers to one that happens twice. Delegating to
`Calendar` makes both cases the platform's problem. `AlarmScheduleCalculatorTests`
pins the behaviour so a future refactor cannot quietly reintroduce the bug.

`DateProviding` abstracts "now" so tests can place themselves anywhere in time.

## Missions

Generators are seeded (`SeededGenerator`, SplitMix64), so a challenge is
reproducible from its seed — essential for debugging a report of "the maths
question was impossible" and for testing generators deterministically.

`RecentChallengeHistory` stores signatures of recently served challenges so the
same question does not appear two mornings running, which would otherwise let
someone memorise their way past the mission.

Anti-cheat is layered rather than a single gate:

| Validator | Rejects |
| --- | --- |
| `StepValidator` | Steps banked before the alarm (it baselines on the first reading), impossible rates, and step counts that disagree with cadence. |
| `ShakeCounter` | Motion without a genuine direction reversal, shakes inside a refractory window, motion without corroborating rotation, and timing too regular to be human. |
| `SquatRepCounter` | Partial range of motion, and bouncing faster than `minRepDuration` (0.6 s). |

## Persistence

`AlarmStore` is an actor writing atomic JSON into the App Group container. The
App Group is required because three processes need the same data: the app, the
widget extension that renders the Live Activity, and the App Intents that back
the alarm alert's buttons.

If the App Group identifier is misconfigured, the failure is quiet — the widget
reads an empty store — which is why the README repeats the three places it must
match.

## What is not here

- **No server.** No account, no sync, no analytics. Statistics are local.
- **No Critical Alerts.** Apple reserves that entitlement for medical and
  public-safety alerts and routinely refuses it for alarm apps. Building on an
  entitlement you will not be granted is how alarm apps ship broken; AlarmKit
  provides break-through behaviour through a supported route.
- **No paywalled missions.** All eleven ship free. A paywall on the mission that
  actually gets someone out of bed sells them a worse alarm.
