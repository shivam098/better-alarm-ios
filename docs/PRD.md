# Product Requirements Document (PRD)

## Alarmy (iOS) — The alarm that actually wakes you up

| Field | Value |
|-------|-------|
| **Product** | Alarmy — Mission Alarm for iOS |
| **Version** | 1.0 |
| **Platform** | iOS / iPadOS (iPhone-first) |
| **Source** | `SRS ALARMY.txt` |
| **Last Updated** | September 2026 |
| **Status** | Draft for engineering review |
| **Owner** | Product |

---

## 1. Executive Summary

Alarmy is an iOS alarm app built on a single promise:

> **If a user sets an alarm because they genuinely need to wake up, the app does everything the operating system allows to get that person awake.**

Ordinary alarms fail because dismissing them requires no consciousness — a half-asleep hand can silence a phone and the user will not remember doing it. Alarmy replaces "tap to dismiss" with **missions**: mental, visual, physical, and location-based tasks that must genuinely be completed before the alarm stops.

Two decisions define the product:

1. **Reliability over polish.** The alarm path is engineered as infrastructure. It works offline, with the app closed, with the screen locked, after a reboot, in Silent Mode, and in Focus.
2. **The entire mission library is free.** Competitors gate the missions that actually work behind a subscription. Alarmy does not. A user gets the complete wake-up toolkit on day one.

---

## 2. Problem Statement

### For the user who cannot afford to oversleep
- Students, shift workers, new parents, people with early flights, and people on medication schedules
- The stock Clock app is trivially dismissed while unconscious; users wake up hours late with no memory of turning it off
- Users resort to placing the phone across the room, setting 12 alarms, or buying a second device — all workarounds for the same failure

### For the user who has already tried a mission alarm
- The good missions (squats, QR scan, photo, combination) are paywalled; the free tier is a math problem they have memorized
- Third-party iOS alarms have historically been unreliable — silenced by Silent Mode, killed in the background, or missed after a reboot
- Missions are punishing rather than purposeful, so users uninstall within a week

### The platform problem
Until iOS 26, third-party apps could not schedule a real alarm. They faked one with chained local notifications and background audio, which iOS was free to silence or throttle. **AlarmKit (iOS 26+) changed this**, but it introduces its own constraint: the system alarm UI always shows a Stop button the app does not control. A mission alarm on iOS must be designed around that fact, not in denial of it.

**Result:** Users pay a subscription for an alarm that either silences itself or lets them dismiss it in their sleep.

---

## 3. Goals & Non-Goals

### 3.1 Goals

| # | Goal |
|---|------|
| G1 | An alarm fires at the correct time, ≥99.9% of the time, with the app closed, offline, locked, and after reboot |
| G2 | An alarm cannot be resolved without evidence the user is conscious |
| G3 | Every mission in the library is free and usable, forever |
| G4 | A sleepy user understands what to do within 3 seconds, without reading anything |
| G5 | The app is honest about iOS limitations instead of silently failing |
| G6 | The user's data (photos, motion, alarms) stays on-device by default |

### 3.2 Non-Goals

| # | Non-Goal | Reason |
|---|----------|--------|
| N1 | Overriding system call audio | Not permitted to third-party apps. The SRS explicitly forbids assuming this. |
| N2 | Shipping v1 dependent on the Critical Alerts entitlement | Apple rarely grants it to alarm apps; it is reserved for health/safety. Treated as an optional enhancement (§6.3.4), never a dependency. |
| N3 | Sleep tracking / sleep-stage detection | Separate product surface; out of scope for v1 |
| N4 | Android parity work | This PRD is iOS-only. Behavior is defined so a future Android build can match where the OS allows (§6.13). |
| N5 | Server-triggered alarms | The SRS requires device-scheduled alarms. No server is in the wake-up path. |
| N6 | Social feeds, friend leaderboards | Scope discipline; revisit post-v1 |

---

## 4. Success Metrics

| Metric | Definition | v1 Target |
|--------|-----------|-----------|
| **Alarm delivery rate** | Alarms that entered `RINGING` within 5s of scheduled time ÷ alarms scheduled | ≥ 99.9% |
| **Mission completion rate** | Alarms resolved as `COMPLETED` ÷ alarms that rang | ≥ 85% |
| **Silent-dismissal rate** | Alarms resolved as `DISMISSED_UNVERIFIED` ÷ alarms that rang | ≤ 5% |
| **Time-to-comprehension** | Median seconds from ring to first valid mission input | ≤ 8s |
| **Median time-to-complete** | Median seconds in `MISSION_ACTIVE` | 20–75s (see §6.6.1) |
| **D30 retention** | Users with ≥1 alarm fired on day 30 | ≥ 40% |
| **Mission diversity** | Users who have used ≥3 distinct missions | ≥ 50% |
| **Uninstall-after-mission** | Uninstalls within 24h of a failed mission | ≤ 2% |
| **Crash-free alarm sessions** | Alarm sessions with no crash between ring and resolution | ≥ 99.95% |

**Guardrail metric:** if median time-to-complete exceeds 90s for any mission, that mission's default difficulty is too high (§6.6.1 — the frustration ceiling).

---

## 5. Target Users & Personas

### Persona 1: The Heavy Sleeper (Aditi, 21, engineering student)
- Sleeps through 6 stacked alarms; has missed two exams
- Turns alarms off in her sleep and has no memory of it
- **Needs:** a mission she physically cannot complete while unconscious
- **Best fit:** Walking (40 steps) or QR code stuck to the bathroom mirror

### Persona 2: The Snooze Spiraler (Rohan, 29, works from home)
- Snoozes 6–8 times, loses 70 minutes every morning
- Not a heavy sleeper — a low-friction one
- **Needs:** limited snoozes and a mental mission that forces cognition
- **Best fit:** Math (medium) with snooze capped at 2

### Persona 3: The High-Stakes Waker (Meera, 34, consultant with 6 AM flights)
- Cannot oversleep; currently uses two phones and a hotel wake-up call
- Distrusts third-party alarms because one failed her once
- **Needs:** proof of reliability, pre-flight confidence, honest warnings
- **Best fit:** Combination mission + Reliability Check (§6.9.3)

### Persona 4: The Skeptic (Sam, 26)
- Downloaded a competitor, hit a paywall on the squat mission, uninstalled
- **Needs:** to discover the full library is genuinely free
- **Best fit:** first-run mission gallery with nothing locked

---

## 6. Platform Foundation — How Alarms Actually Work on iOS

> This section is normative. Every feature below depends on it. It is placed before the feature list deliberately: on iOS, the alarm mechanism dictates the product design, not the reverse.

### 6.1 Verified iOS capabilities

| Capability | Status | Notes |
|-----------|--------|-------|
| `AlarmKit` system alarms | ✅ iOS 26+ | Real system alarms; survive app termination and reboot |
| Breaks through Silent Mode | ✅ via AlarmKit | Same class as the built-in Clock app |
| Breaks through Focus / DND | ✅ via AlarmKit | |
| One-time + repeating schedules | ✅ | `fixed` (absolute) or `relative` (timezone-adjusting) |
| Custom alarm sound | ✅ | `AlertConfiguration.AlertSound.named`; file in app bundle or `Library/Sounds` |
| Custom snooze / secondary button | ✅ | `secondaryButton` + `secondaryButtonBehavior` (`.countdown` or custom App Intent) |
| Opening the app from the alert | ✅ | `LiveActivityIntent` with `openAppWhenRun = true` |
| Lock Screen / Dynamic Island / StandBy presence | ✅ | Via ActivityKit Live Activity bound to `AlarmAttributes` |
| **Suppressing the system Stop button** | ❌ **Not possible** | Stop is mandatory in the AlarmKit alert |
| Forcing audio over an active phone call | ❌ | Not available to third-party apps |
| Critical Alerts (mute bypass for notifications) | ⚠️ Entitlement | Requires Apple approval; alarm apps routinely denied |
| Arbitrary background execution to run an alarm | ❌ | Never rely on it |

**Requires:** `NSAlarmKitUsageDescription` in `Info.plist` and runtime authorization via `AlarmManager.shared.requestAuthorization()`. Users can revoke it in Settings at any time.

Apple's own guidance notes AlarmKit is *not* a replacement for critical alerts or time-sensitive notifications. Alarmy uses it for exactly what it is designed for: a scheduled, permanent, user-consented wake-up alert.

### 6.2 The central design constraint — the mandatory Stop button

The AlarmKit alert always renders a **Stop** button. A user can therefore stop the sound without completing a mission. This would defeat the entire product if left unhandled.

**Resolution — the two-button model plus Mission Guard:**

| Alert element | Alarmy binding |
|--------------|----------------|
| **Primary (Stop)** | Labeled **"Stop"**. Stops audio, but resolves the alarm as `DISMISSED_UNVERIFIED`, **not** `COMPLETED`. |
| **Secondary (custom)** | Labeled **"Start Mission"**. Custom `LiveActivityIntent` with `openAppWhenRun = true`; launches the mission runner. |

**REL-1 — Mission Guard (default ON for any alarm with a mission).**
When an alarm has a mission, the app **pre-schedules a watchdog chain** of follow-up AlarmKit alarms at the time the alarm is created:

```
T+0   primary alarm
T+1m  watchdog #1
T+3m  watchdog #2
T+6m  watchdog #3
T+10m watchdog #4  … up to the configured cap
```

- Completing the mission **cancels every remaining watchdog** in the chain.
- Tapping **Stop** without completing the mission does **not** cancel them — the alarm returns.
- The chain is **pre-scheduled, never scheduled reactively**, because the app cannot rely on background execution to re-arm itself after a Stop.
- Default cap: **6 watchdogs over 30 minutes.** User-configurable (Off / 15m / 30m / 60m / Until completed).
- Watchdog alerts escalate: volume ramps to maximum, and the alert title changes to `"Mission not completed — <alarm name>"`.

**REL-2 — Escalating difficulty.** Per SRS, repeated failure/evasion makes the alarm harder to ignore, never easier. On watchdog #3 and beyond, the mission difficulty increases one step (capped at the mission's maximum), and the "Stop" path is visually de-emphasized in the in-app runner.

**REL-3 — Chain budget.** Watchdogs consume scheduling slots. The scheduler enforces a global cap on pending system alarms (§6.7.4) and prioritizes: next-24h alarms > repeating alarms > watchdogs of distant alarms.

### 6.3 Delivery tiers (graceful degradation)

The app selects the highest tier the device supports and **tells the user which tier is active**.

#### 6.3.1 Tier 1 — AlarmKit (iOS 26+, authorized) — *the supported configuration*
Full reliability. Breaks Silent Mode and Focus. Survives reboot and termination. This is the target for ~all v1 users.

#### 6.3.2 Tier 2 — Notification chain (iOS 26+ with AlarmKit denied)
`UNCalendarNotificationTrigger` chain with a ≤30s custom sound, repeated at 30s intervals for up to 15 minutes, plus a Live Activity. **Respects the mute switch and Focus** — the app must display a persistent warning: *"Your alarm will not sound if your phone is on silent. Enable Alarm access to fix this."* with a one-tap deep link to Settings.

#### 6.3.3 Tier 3 — Legacy fallback (pre-iOS 26)
As Tier 2, plus a foreground `AVAudioSession` (`.playback`) takeover when the app happens to be running. **Not marketed as reliable.** Minimum deployment target is a scoping decision (§14 Q1); the recommendation is **iOS 26.0 minimum for v1**, which eliminates Tiers 2–3 as anything but a permission-denied state.

#### 6.3.4 Optional — Critical Alerts
If Apple grants the entitlement, it is used **only** to reinforce Tier 2/3 and the in-call path (§6.4.1). The product must ship and fully function without it.

### 6.4 Interruption handling

#### 6.4.1 Phone calls and VoIP (INT-1 … INT-6)

The app uses `CXCallObserver` to observe call state. It **never** attempts to seize call audio.

| Scenario | Required behavior |
|---------|-------------------|
| **INT-1** Call in progress when alarm fires | Alarm enters `RINGING` **regardless of whether audio played**. The system may duck or suppress the tone; that is not treated as a miss. Live Activity + Dynamic Island + Lock Screen alert remain present and persistent. |
| **INT-2** Call starts *after* the alarm begins | Alarm stays in its current state. It is **not** auto-dismissed, auto-snoozed, or auto-completed. |
| **INT-3** Call ends while the alarm is still active | The alarm **re-presents at full prominence within 2 seconds**, and the user is prompted to complete the mission. |
| **INT-4** Alarm and call at the same instant | Alarm state machine wins on bookkeeping; audio yields to the system. Result is `RINGING (audio suppressed)`, never `MISSED`. |
| **INT-5** VoIP calls | Same behavior wherever `CXCallObserver` reports the state. Where a VoIP app does not report to CallKit, the alarm behaves normally — documented as a known limitation. |
| **INT-6** Missed-audio disclosure | The post-alarm summary states *"Your alarm was silenced by a phone call"* so the user is never left thinking the app failed. |

**Explicit non-assumption:** Alarmy will not claim, in UI or marketing, that it can force sound over a call.

#### 6.4.2 Media, headphones, and audio routes (INT-7 … INT-10)

| # | Requirement |
|---|-------------|
| INT-7 | If media is playing, the alarm **interrupts** it (`.playback` with `.duckOthers` for pre-alert; full interruption at ring). Media is **not** resumed automatically after dismissal — the user is awake now. |
| INT-8 | **The alarm must never be audible only in a disconnected or unworn accessory.** When a route other than the built-in speaker is active, the alarm plays on the **built-in speaker** (`overrideOutputAudioPort(.speaker)`) in addition to the active route where the OS permits. |
| INT-9 | `AVAudioSession.routeChangeNotification` is observed for the entire alarm session. Unplugging headphones mid-alarm must not stop the alarm; it re-routes within 1 second. |
| INT-10 | A Bluetooth route that has disconnected or gone idle is treated as unavailable — speaker is used. |

#### 6.4.3 Silent Mode and Focus (INT-11)

| Tier | Behavior | Disclosure |
|------|----------|-----------|
| Tier 1 | **Sounds through Silent Mode and Focus.** | "Your alarm will ring even on silent." |
| Tier 2/3 | **Will be silenced.** | Persistent, dismissible-once warning + Settings deep link. |

The app **never** assumes normal audio behavior is available. Tier is re-evaluated on every launch and every alarm creation.

#### 6.4.4 Overlapping alarms (INT-12)

**Rule (deterministic, user-visible in Settings):**
1. Alarms scheduled within **90 seconds** of each other are treated as **one alarm session**.
2. The session adopts the **earliest** alarm's time and the **hardest** mission among them (by difficulty rank).
3. The names of all merged alarms are shown: *"Gym + Class"*.
4. Completing the mission resolves **all** alarms in the session; each is logged individually in history.
5. Alarms more than 90s apart are strictly sequential: the second cannot ring until the first is resolved, snoozed, or its watchdog chain is exhausted.
6. **Never** does one alarm silently swallow another.

### 6.5 Reboot, Low Power Mode, and system-level restrictions (REL-4 … REL-8)

| # | Requirement |
|---|-------------|
| REL-4 | AlarmKit alarms are system-scheduled and survive reboot. On first launch after a reboot, the app **reconciles** its store against `AlarmManager` state and reschedules anything missing. |
| REL-5 | Live Activities are unavailable until the device is first unlocked after reboot. The alarm must still fire and present its system alert; the rich UI degrades silently. |
| REL-6 | Low Power Mode does not affect AlarmKit delivery, but does affect in-app mission sensors. The app warns before an alarm whose mission needs sensors: *"Low Power Mode may slow step counting."* |
| REL-7 | If AlarmKit authorization is revoked, or Notifications are disabled, the app surfaces a **blocking, red, persistent banner on the alarm list** — not a toast — and disables the "alarm will wake you" claim. |
| REL-8 | The app **never** instructs the user to keep it open, disable Low Power Mode, or leave it in the app switcher for alarms to work. |

### 6.6 Product principles

| # | Principle |
|---|-----------|
| P1 | **Reliability beats polish.** If a visual effect risks the alarm path, the effect loses. |
| P2 | **Break the sleep state; don't punish the sleeper.** Difficulty exists to induce consciousness, nothing more. |
| P3 | **Different people wake differently** — mental, visual, physical, and location missions all ship. |
| P4 | **Never mistake presence for consciousness.** Opening the app, unlocking the phone, or moving it is never completion. |
| P5 | **Never rely on one anti-cheat mechanism.** Every verification is layered (§6.6.3). |
| P6 | **Be honest about limits.** Say what iOS won't allow instead of failing quietly. |
| P7 | **The complete toolkit is free.** No mission is ever visible-but-locked. |

---

## 7. Feature Requirements

### 7.1 Alarm Management (ALM)

| # | Requirement | Priority |
|---|-------------|----------|
| ALM-1 | Create an unlimited number of alarms (soft cap of 100 with a friendly message; scheduling budget per §6.7.4) | P0 |
| ALM-2 | Set an exact time (hour/minute; 12h & 24h honoring device locale) | P0 |
| ALM-3 | Choose one-time or repeat on specific weekdays | P0 |
| ALM-4 | Name an alarm ("Class", "Gym", "Wake up") with quick-pick suggestions | P0 |
| ALM-5 | Toggle an alarm on/off without deleting it | P0 |
| ALM-6 | Edit any property of an existing alarm, including its mission, without recreating it | P0 |
| ALM-7 | Delete an alarm (swipe + confirm; undo snackbar for 5s) | P0 |
| ALM-8 | Duplicate an existing alarm, copying all settings including mission config | P0 |
| ALM-9 | Alarm list visually distinguishes active from inactive alarms at a glance (not just a small toggle — inactive rows are dimmed) | P0 |
| ALM-10 | A persistent header shows the **next alarm to ring**, with relative time ("in 7h 12m") and its name | P0 |
| ALM-11 | Each row shows: time, name, repeat days, mission icon, and required-permission indicator | P0 |
| ALM-12 | Editing an alarm cancels and rebuilds its full watchdog chain atomically | P0 |

### 7.2 Scheduling & Reliability (REL)

Covered normatively in §6.2–6.5. Additional:

| # | Requirement | Priority |
|---|-------------|----------|
| REL-9 | Alarms function with **zero network connectivity**. No network call is in the scheduling, ringing, or mission path. (Exception: none. Photo/QR/math/memory verification is all on-device.) | P0 |
| REL-10 | The device clock and system alarm scheduling are the source of truth. No server wake-up. | P0 |
| REL-11 | All alarm state transitions are written to a local durable store **before** UI updates, so a crash mid-alarm cannot lose the record | P0 |
| REL-12 | On launch, a reconciliation pass detects and repairs: missing system alarms, orphaned watchdogs, and alarms whose fire time has passed unhandled (§7.12) | P0 |

### 7.3 Alarm Ringing Experience (RNG)

| # | Requirement | Priority |
|---|-------------|----------|
| RNG-1 | The alarm is unmistakably an alarm, not a notification: full-screen takeover in-app, maximum-prominence system alert, distinct sound, and haptics | P0 |
| RNG-2 | Volume **ramps** from ~40% to 100% over 20 seconds by default (gentle-start, configurable off), then holds at maximum | P1 |
| RNG-3 | Vibration is per-alarm configurable (on/off). Where the system controls it (AlarmKit), the setting reflects what the OS honors. | P0 |
| RNG-4 | The alarm does not stop because the app went to the background, the screen locked, or the user switched apps | P0 |
| RNG-5 | The required action is obvious the instant the alarm starts — the mission's first step is visible above the fold with no scrolling and no onboarding text | P0 |
| RNG-6 | A Live Activity (Lock Screen + Dynamic Island) shows live mission progress, e.g. "27/50 steps" | P1 |
| RNG-7 | Maximum ring duration before auto-resolution: **15 minutes** per alarm instance, then `MISSED` — but the watchdog chain continues (§6.2) | P0 |
| RNG-8 | Screen brightness is raised and the runner uses a high-contrast, large-type layout designed for unfocused eyes | P1 |

### 7.4 Snooze (SNZ)

| # | Requirement | Priority |
|---|-------------|----------|
| SNZ-1 | Snooze duration configurable per alarm: 1, 3, 5, 10, 15, 20, 30 min (default **9 min**) | P0 |
| SNZ-2 | Snooze can be **disabled entirely** per alarm and globally | P0 |
| SNZ-3 | Maximum snooze count per alarm, configurable (Unlimited / 1 / 2 / 3 / 5; default **3**) | P0 |
| SNZ-4 | **Snoozing never counts as completing an alarm.** It is a distinct terminal-adjacent state and is logged separately. | P0 |
| SNZ-5 | The snooze button is deliberately smaller and lower-contrast than the mission CTA | P1 |
| SNZ-6 | Optional **"Snooze costs a mission"**: the mission must be completed *before* the snooze is granted | P1 |
| SNZ-7 | When the snooze limit is reached, the button is removed and the mission is the only path forward | P0 |
| SNZ-8 | Snooze durations shorten on repeat (9 → 5 → 3 min) when "escalating snooze" is enabled | P2 |

### 7.5 Mission Library (MSN)

All missions below are **free**. There is no locked mission, no trial mission, and no visible-but-unusable mission (§7.16).

#### 7.5.1 Mission catalogue

| ID | Mission | Type | Sensors / Permissions | Difficulty axis | Priority |
|----|---------|------|----------------------|-----------------|----------|
| M-00 | **Default (Slide to stop)** | — | None | — | P0 |
| M-01 | **Math** | Mental | None | Operand size, operations, problem count (1–10) | P0 |
| M-02 | **Find the Missing Symbol** | Visual | None | Grid size, symbol-set similarity, distractor count | P0 |
| M-03 | **Memory** | Mental/visual | None | Sequence length, display time, modality (numbers/colors/shapes/patterns) | P0 |
| M-04 | **Typing** | Mental/motor | None | Phrase length (20–120 chars), case sensitivity, phrase count | P0 |
| M-05 | **Shake** | Physical | Motion (accelerometer/gyro) | Shake count (10–200) | P0 |
| M-06 | **Walking (Steps)** | Physical | Motion & Fitness | Step count (10–500) | P0 |
| M-07 | **Squat** | Physical | Camera + Motion | Rep count (3–50) | P1 |
| M-08 | **Photo** | Location/physical | Camera | Target strictness | P0 |
| M-09 | **Barcode / QR** | Location/physical | Camera | Code count (1–3) | P0 |
| M-10 | **Combination** | Mixed | Union of children | Number of chained missions (2–5) | P1 |

#### 7.5.2 Per-mission requirements

**M-01 Math**
- Difficulty levels: Easy (single-digit +/−), Medium (two-digit +/−/×), Hard (three-digit, mixed ops), Very Hard (multi-step, order of operations)
- Problem count configurable 1–10 (default 3 at Medium)
- **Problems are generated per instance, never repeated from a fixed pool**; a seed-history check prevents repeating any problem the user has seen in the last 30 days
- The answer is validated before dismissal is permitted; a wrong answer replaces the problem with a **new** one (never the same one)
- No answer reveal, no skip

**M-02 Find the Missing Symbol**
- A grid/pattern of symbols, numbers, shapes, or colors is displayed with exactly one element missing
- The user selects the missing element from candidate options
- Difficulty controls grid size (3×3 → 5×5), distractor count (3 → 8), and **visual similarity of distractors** (the real difficulty lever)
- Patterns are procedurally generated; memorization across mornings is impossible
- Rotating/mirrored variants ensure the same seed does not repeat visually

**M-03 Memory**
- A sequence of numbers, symbols, colors, or patterns is shown briefly, then hidden; the user reproduces it
- Difficulty controls sequence length (3–9), display duration (2.5s → 0.8s), and modality
- Up to 3 attempts per round; each failure regenerates a **new** sequence
- Optional "increasing" mode where each successful round lengthens the sequence

**M-04 Typing**
- The user types a displayed phrase exactly
- Phrase length configurable; default ~45 characters — long enough to be genuinely hard while half-asleep
- Paste is **disabled**; autocorrect, predictive text, and dictation are **disabled**
- Phrase library is large and randomized; no phrase repeats within 30 days
- Configurable case sensitivity (default: off — punctuation and case forgiving, spelling strict)

**M-05 Shake**
- The user shakes the phone until the target count is reached
- `CoreMotion` device-motion at 50 Hz; a shake counts only above an acceleration-magnitude threshold with a required **direction reversal** and a refractory period
- **Anti-cheat:** perfectly periodic motion (machine-like variance below a floor) is rejected; rotational + linear components must both be present
- Live counter and haptic tick per counted shake

**M-06 Walking (Steps)**
- Target steps configurable 10–500 (default 30)
- Uses `CMPedometer` **live streaming from the moment the mission starts** — historical step queries are never used, so pre-banked steps cannot satisfy it
- **Opening the app, unlocking the phone, or waving/shaking the phone must not count as steps.** The step source must report genuine gait; a cross-check against device-motion cadence rejects hand-waving patterns
- Live progress: "27/50 steps", plus Live Activity mirror
- If the user stops for >60s, progress holds (never resets) and a nudge plays

**M-07 Squat**
- Target reps configurable 3–50 (default 10)
- Primary: on-device `Vision` human body-pose estimation via front camera, counting reps by hip/knee joint angle crossing a depth threshold and returning
- Secondary: device-motion vertical displacement signature as corroboration
- **Real-time feedback** on every rep: rep counter, "Go lower" / "Stand up fully" coaching, and a haptic on each counted rep
- Partial, accidental, or out-of-frame movements are **not** counted; the UI says why ("Move back so your knees are visible")
- Video frames are processed in-memory and **never written to disk or transmitted** (§7.14)
- Requires adequate lighting; if pose confidence is too low for 20s, offer the Walking mission as a substitute (§7.8)

**M-08 Photo**
- During setup, the user registers a target: a physical object or location (e.g. the bathroom sink, the kettle) by taking 1–3 reference photos
- On alarm, the user must capture a photo of that target
- **Verification (layered, all on-device):**
  1. On-device visual embedding similarity between the new capture and the stored reference(s) above a threshold
  2. Coarse structural/histogram corroboration to reject a similarity false-positive
  3. **Freshness:** the image must come from the live capture session — the photo library is inaccessible from the mission runner, and only frames originating from the active `AVCaptureSession` in this session are accepted
  4. **Anti-replay:** a photo of a screen showing an old photo is rejected via screen/moiré and flatness heuristics; additionally the capture must show natural inter-frame variation (a static rephotograph of a print/screen fails the liveness check)
- **On failure, the app states the specific reason** — "That doesn't look like your kettle", "This looks like a photo of a screen", "Too dark to tell" — never a bare "Failed"
- After 5 consecutive failures, the app offers a fallback mission rather than trapping the user (the alarm keeps ringing throughout; §7.7)
- Reference photos are stored **locally only**, encrypted, and deleted with the alarm

**M-09 Barcode / QR**
- During setup, the user registers a specific barcode/QR code — typically stuck on the bathroom mirror, kettle, or fridge
- The alarm remains active until the **registered** code is scanned; any other code shows "That's not the right code"
- Multiple codes per alarm (must scan all, in any order) for higher difficulty
- The app can generate and share a printable QR code for users without a convenient barcode
- **Anti-cheat:** a screenshot of the code taken in advance still requires the physical scan act; the app warns that photographing the code defeats the purpose, and a same-position/instant re-scan of the same frame is rejected

**M-10 Combination**
- The user chains 2–5 missions in a chosen order (e.g. *Math → 50 steps → scan QR*)
- Any mission type can be chained; the union of permissions is required and disclosed at setup
- Progress across the chain is shown ("Step 2 of 3")
- Failing one link does not reset the whole chain; it retries that link with a **new** instance
- Combination is free like everything else

#### 7.5.3 Anti-cheat & integrity (MSN-INT)

| # | Requirement |
|---|-------------|
| MSN-INT-1 | **No mission may be bypassed by tapping, swiping, force-quitting, or backgrounding the app.** Force-quit mid-mission leaves the alarm unresolved; the watchdog chain (§6.2) brings it back. |
| MSN-INT-2 | Every physical mission uses **at least two independent signals** (e.g. pedometer + motion cadence; pose + motion displacement; embedding + liveness) |
| MSN-INT-3 | Deliberate defeat attempts are anticipated: pre-banked steps, mechanical shaking, screen-rephotography, screenshotted QR codes, changing the system clock, and airplane mode — each has a stated mitigation |
| MSN-INT-4 | Changing the system clock forward does **not** resolve a ringing alarm, and does not fast-forward a snooze (elapsed time is measured against a monotonic clock) |
| MSN-INT-5 | Incorrect attempts **never** dismiss the alarm |
| MSN-INT-6 | Unlimited failed attempts are handled without crash, freeze, or dead-end; each failure regenerates a fresh instance |
| MSN-INT-7 | The mission runner blocks navigation away: no swipe-back, no tab bar, no in-app escape. Control Center / app switcher cannot be blocked by any app — handled by MSN-INT-1 instead. |

### 7.6 Mission Engine & Dismissal State Machine (MEN)

#### 7.6.1 States

```
SCHEDULED ──► ARMED ──► RINGING ──► MISSION_ACTIVE ──► COMPLETED ✅
                          │              │
                          │              ├─► FAILED_ATTEMPT ─┐ (loops back)
                          │              └──────────────────◄┘
                          ├─► SNOOZED ──► (re-enters RINGING)
                          ├─► DISMISSED_UNVERIFIED ⚠️  (system Stop, no mission)
                          └─► MISSED ❌ (never handled)
```

#### 7.6.2 Requirements

| # | Requirement |
|---|-------------|
| MEN-1 | The app distinguishes and separately records three outcomes: **"user dismissed the alarm"** (`DISMISSED_UNVERIFIED`), **"user completed the mission"** (`COMPLETED`), and **"the alarm was never successfully handled"** (`MISSED`) |
| MEN-2 | **Opening the app is never completion.** Only a verified mission result transitions to `COMPLETED`. |
| MEN-3 | The alarm continues until the mission is genuinely completed, the watchdog chain is exhausted, or the user explicitly turns the alarm off in Settings |
| MEN-4 | Closing the app, locking the phone, or navigating away during `MISSION_ACTIVE` does not resolve the alarm; on return, the mission resumes with progress intact (steps/reps are preserved, not reset) |
| MEN-5 | Only `COMPLETED` cancels the remaining watchdog chain |
| MEN-6 | Every transition is timestamped and persisted for history (§7.10) |
| MEN-7 | The mission library is **plug-in shaped**: a `Mission` protocol (`configure` / `start` / `evaluate` / `progress` / `requiredPermissions`) so new missions ship without redesigning the alarm system |

### 7.7 Permissions & Degradation (PRM)

| # | Requirement |
|---|-------------|
| PRM-1 | **A basic alarm requires only Notifications and AlarmKit authorization.** No camera, motion, or health permission is requested to use the app's core function. |
| PRM-2 | Permissions are requested **just-in-time**, at the moment a user selects a mission that needs them — never at first launch in a wall of prompts |
| PRM-3 | Each request is preceded by a plain-language screen: which permission, why, and what breaks without it |
| PRM-4 | If a permission is denied, the mission is **not** silently broken: the user is offered the closest equivalent mission (Photo → QR → Typing; Squat → Walking → Shake; Walking → Shake → Math) |
| PRM-5 | If a required sensor or permission becomes unavailable **at ring time**, the alarm still rings and automatically substitutes the configured fallback mission, telling the user why |
| PRM-6 | Each mission card in the picker displays its permission requirements **before** selection |
| PRM-7 | An alarm can never end up in a state where it rings but cannot be completed |

### 7.8 Sounds & Audio (SND)

| # | Requirement |
|---|-------------|
| SND-1 | A curated built-in sound library (gentle → aggressive), all free |
| SND-2 | Different sounds selectable per alarm |
| SND-3 | **Preview any sound before saving**, at a safe preview volume, with an obvious stop control |
| SND-4 | Alarm sound files are bundled locally (≤30s, looping) — no network fetch at ring time |
| SND-5 | Per-alarm volume, with gentle-ramp toggle |
| SND-6 | Vibration pattern selectable where the OS permits |
| SND-7 | Optional custom sound import (from Files) in a later release | 

### 7.9 History, Statistics & Streaks (HIS)

| # | Requirement | Priority |
|---|-------------|----------|
| HIS-1 | Record for every alarm instance: scheduled time, actual trigger time, outcome, mission used, mission difficulty, attempts, snooze count, and **time-to-complete** | P0 |
| HIS-2 | Record whether the alarm was completed, snoozed, dismissed unverified, or missed | P0 |
| HIS-3 | Browsable alarm history, newest first, grouped by day | P0 |
| HIS-4 | Wake-up streaks (consecutive days with a `COMPLETED` alarm) with a single-day grace token per week so one bad morning doesn't erase months | P1 |
| HIS-5 | Statistics: average wake-up time, average snoozes, missed count, completion rate, average time-to-complete, most-used mission | P1 |
| HIS-6 | **Statistics must be understandable, not a dashboard.** One screen, ≤5 headline numbers, one trend chart. Depth is opt-in behind "See details". | P0 |
| HIS-7 | History is stored locally and available offline; export to CSV | P2 |
| HIS-8 | History retention configurable (90 days / 1 year / forever; default 1 year) | P1 |

### 7.10 Settings & Defaults (SET)

| # | Requirement |
|---|-------------|
| SET-1 | **Sensible defaults**: creating an alarm requires only picking a time. Everything else is pre-filled. |
| SET-2 | Global defaults for new alarms: sound, volume, vibration, snooze duration/limit, mission, difficulty, Mission Guard duration |
| SET-3 | The app remembers the user's last-used mission and settings and offers them as the default next time |
| SET-4 | Mission difficulty is changeable without recreating the alarm |
| SET-5 | Advanced settings (Mission Guard, overlap rule, escalation) live behind an "Advanced" disclosure so the basic path stays simple |
| SET-6 | A **Reliability Check** screen: verifies AlarmKit authorization, notification permission, Focus configuration, and Low Power Mode, showing a single green/amber/red verdict — designed for the night-before-a-flight user |

### 7.11 Time, Time Zones & Clock Changes (TIM)

| # | Requirement |
|---|-------------|
| TIM-1 | Repeating alarms use a **relative (wall-clock) schedule**: "7:00 AM local" follows the user across time zones |
| TIM-2 | One-time alarms default to wall-clock, with an explicit **"Keep absolute time"** option for travellers who mean a specific instant |
| TIM-3 | On time-zone change, the app reconciles all alarms and shows a single, non-alarming notice: *"Time zone changed to IST. Your 7:00 AM alarms will ring at 7:00 AM here."* |
| TIM-4 | DST transitions: a "spring-forward" alarm at a non-existent local time fires at the **next valid instant**; a "fall-back" alarm at a duplicated local time fires **once, on the first occurrence** |
| TIM-5 | **No clock change, time-zone change, DST shift, or reconciliation pass may create a duplicate alarm.** All scheduling is idempotent, keyed by a stable alarm ID + occurrence key. |
| TIM-6 | If an alarm's time passed while the device was off or unavailable, the app applies a clear, user-visible rule (see TIM-7) |
| TIM-7 | **Missed-window rule (configurable, default "Grace period"):** <br>• **Grace period (default):** if the device becomes available within **15 minutes** of the scheduled time, the alarm triggers immediately. Beyond that, it is skipped and logged as `MISSED`. <br>• **Always skip** and log. <br>• **Always trigger** on next availability. |
| TIM-8 | The chosen behavior is communicated **at the moment it happens**: *"Your 6:30 alarm was missed — your phone was off."* Never silent. |

### 7.12 Data, Offline & Sync (DAT)

| # | Requirement |
|---|-------------|
| DAT-1 | **All alarm data is local-first and fully functional offline.** The local store is the source of truth for scheduling. |
| DAT-2 | Optional iCloud (CloudKit) sync of alarms, settings, and history, tied to the user's Apple Account — no separate login required |
| DAT-3 | **If sync fails, alarms continue to work.** Sync failure never blocks, delays, or alters an alarm. |
| DAT-4 | Signing in on another device restores alarms and preferences |
| DAT-5 | **Sync conflicts are resolved by field-level merge, never a silent overwrite.** If two devices changed the same alarm's time or mission, the app keeps both, surfaces a conflict card, and asks the user to choose. Nothing is discarded silently. |
| DAT-6 | If an account system is introduced, the user can delete their account and all associated cloud data from within the app, with confirmation and a stated completion window |
| DAT-7 | Local data is protected with file-level encryption; reference photos use `.completeUntilFirstUserAuthentication` so alarms still work before first unlock |

### 7.13 Privacy (PRV)

| # | Requirement |
|---|-------------|
| PRV-1 | Each mission states, in the picker, **exactly what it collects**: "Uses the camera. Photos are checked on your device and never uploaded." |
| PRV-2 | **Camera frames, pose data, and motion data are processed on-device and never transmitted.** Squat/photo frames are held in memory only. |
| PRV-3 | Photo-mission captures are deleted **immediately** after verification. Only the reference image(s) persist, locally and encrypted, and are deleted with the alarm. |
| PRV-4 | Motion/step data is read only during an active mission and only for the duration of that mission. No background collection. No HealthKit write access. |
| PRV-5 | The user controls which optional data is stored or synced: history, statistics, and reference photos are each independently toggleable |
| PRV-6 | A one-screen, plain-language privacy summary is reachable from Settings |
| PRV-7 | No third-party analytics SDK in the alarm or mission path; telemetry is aggregate, opt-in, and contains no images or raw sensor traces |

### 7.14 Safety (SAF)

| # | Requirement |
|---|-------------|
| SAF-1 | **No mission may require a physically risky action.** No jumping, no stairs, no leaving the home, no timed sprints. |
| SAF-2 | Physical missions have configurable intensity so users with limited mobility can choose an appropriate level, and every physical mission has a non-physical alternative |
| SAF-3 | If `CMMotionActivityManager` indicates automotive/cycling activity, physical and camera missions are **suspended** and replaced with an audible alert plus a simple non-visual dismissal — the app must never encourage phone interaction while driving |
| SAF-4 | The Squat mission shows a brief safety note on first use and a "Switch mission" escape at any time |
| SAF-5 | Mission difficulty is capped at levels validated as completable within 3 minutes by a sleepy user |

### 7.15 Mission Access & Monetization (MON)

| # | Requirement |
|---|-------------|
| MON-1 | **The complete mission library is free**, including missions competing apps place behind a subscription (Squat, Photo, QR, Combination, Memory, Missing Symbol) |
| MON-2 | **No mission is ever visible-but-locked.** There is no lock icon, no "PRO" badge, and no upsell inside the mission picker. |
| MON-3 | No subscription is required to access the core set of wake-up challenges, difficulty settings, or Mission Guard |
| MON-4 | If optional paid features are introduced later, they must add **peripheral** value (themes, premium sound packs, extended history, widgets). Payment may never gate the ability to wake up. |
| MON-5 | The positioning is *"you get the complete wake-up toolkit"* — not *"five missions and a paywall"* — and first-run onboarding says so explicitly |

### 7.16 Discovery, Feedback & Tone (UX)

| # | Requirement |
|---|-------------|
| UX-1 | Live progress during every mission: "27/50 steps", "6/10 squats", "Problem 2 of 3" | 
| UX-2 | Immediate visual + haptic feedback the instant a rep, answer, scan, or step is recognized |
| UX-3 | An unmistakable completion moment: full-screen confirmation, distinct haptic, "Good morning" |
| UX-4 | A mission gallery lets users browse and **try** any mission outside of an alarm (practice mode) |
| UX-5 | The app periodically suggests an unused mission — *"You've used Math 30 times. Try Missing Symbol?"* — at most once every 2 weeks, dismissible |
| UX-6 | Copy is warm and never punitive. No shaming, no guilt, no "you failed again". |
| UX-7 | The whole flow is understandable without a manual; no mission requires reading more than one short sentence |
| UX-8 | Full VoiceOver, Dynamic Type, and Reduce Motion support; every mission has an accessible completion path (§14 Q4) |
| UX-9 | Every mission card **clearly indicates its difficulty** (a 1–5 intensity meter) and its type (mental / visual / physical / location) before selection, alongside its permission requirements (PRM-6) |

---

## 8. Key User Flows

### 8.1 Create an alarm (target: under 10 seconds)
1. Tap **+**
2. Scroll the time picker → 6:30 AM
3. *(Everything else is pre-filled from global defaults.)*
4. Tap **Save**
5. Confirmation: "Alarm in 8h 12m · Math mission"

### 8.2 Alarm fires (Tier 1, mission = Walking 40 steps)
1. **6:30:00** — system alarm alert appears over the Lock Screen; sound plays through Silent Mode; device vibrates
2. Alert shows: **"Gym"**, `Stop` and **`Start Mission`**
3. User taps **Start Mission** → app launches directly into the runner (no splash, no home screen)
4. Full-screen: **"Walk 40 steps"** · `0/40` · large progress ring
5. Sound continues at full volume throughout
6. Steps stream live; haptic tick every 5 steps; Live Activity mirrors progress
7. **40/40** → sound stops, "Good morning" confirmation, remaining watchdogs cancelled
8. History records: `COMPLETED`, 41s, Walking, 0 snoozes

### 8.3 User taps Stop instead (the critical path)
1. User taps **Stop** → audio stops → state = `DISMISSED_UNVERIFIED`
2. Watchdog chain is **not** cancelled
3. **6:31:00** — watchdog #1 fires, louder, titled *"Mission not completed — Gym"*
4. User taps **Start Mission**, completes it → all watchdogs cancelled
5. History records one `DISMISSED_UNVERIFIED` and one `COMPLETED`, with the gap surfaced in stats

### 8.4 Call arrives during the alarm
1. Alarm is `RINGING`; incoming call → system takes audio
2. State remains `RINGING (audio suppressed)`; Live Activity persists in the Dynamic Island
3. Call ends → within 2s the alarm re-presents at full prominence with the mission
4. History: `COMPLETED`, annotated *"interrupted by call"*

### 8.5 Photo mission fails
1. User photographs the wrong object
2. Sound continues; message: **"That doesn't look like your kettle. Try getting closer."**
3. Attempt 5 fails → **"Having trouble? Switch to Math instead."** (alarm still ringing)
4. History logs 5 failed attempts, final outcome, and mission substitution

---

## 9. Data Model (logical)

```
Alarm
  id, name, time, repeatDays[], enabled, scheduleMode (relative|absolute)
  soundId, volume, gentleRamp, vibrationEnabled
  snoozeEnabled, snoozeDuration, snoozeLimit, snoozeCostsMission
  missionConfig  → MissionConfig
  missionGuard   → { enabled, capMinutes, escalate }
  fallbackMissionId
  createdAt, updatedAt, syncRevision

MissionConfig
  type (math|missingSymbol|memory|typing|shake|steps|squat|photo|qr|combination|none)
  difficulty, targetCount, params{}
  children[]        // combination only, ordered
  referenceAssetIds[]  // photo/QR, local-only

AlarmOccurrence            // one per fire
  id, alarmId, occurrenceKey (idempotency)
  scheduledAt, firedAt, resolvedAt
  outcome (COMPLETED|SNOOZED|DISMISSED_UNVERIFIED|MISSED)
  missionType, difficulty, attempts, failureReasons[]
  snoozeCount, timeToCompleteMs
  audioSuppressedReason (call|route|silent|none)
  deliveryTier (1|2|3)

WatchdogAlarm
  id, parentOccurrenceKey, fireAt, index, systemAlarmId

UserDefaultsProfile
  defaultMission, defaultDifficulty, defaultSound, defaultSnooze,
  lastUsedMission, missedWindowRule, overlapRule, historyRetention
```

**Idempotency:** `occurrenceKey = alarmId + localDate + localTime`. Any reconciliation, clock change, or sync merge that produces the same key is a no-op — this is the mechanism satisfying TIM-5.

---

## 10. Non-Functional Requirements

| Area | Requirement |
|------|-------------|
| **Reliability** | Alarm delivery ≥99.9%; no alarm-path code may depend on network, server, or background execution |
| **Latency** | Ring → mission runner visible ≤ 1.5s cold start. Mission input → feedback ≤ 100ms. |
| **Battery** | ≤2% additional daily drain with 5 alarms. Sensors run only during `MISSION_ACTIVE`. |
| **Storage** | ≤50 MB app; ≤20 MB user data at default retention |
| **Scheduling budget** | Global cap on pending system alarms with documented prioritization (§6.2 REL-3); the Tier 2/3 path must respect the 64-pending-notification limit |
| **Offline** | 100% of core functionality offline |
| **Accessibility** | WCAG 2.2 AA contrast; VoiceOver on every control; Dynamic Type to XXL; every mission has an accessible path |
| **Localization** | Locale-correct time formats and first-day-of-week from v1; string externalization from day one |
| **Testing** | Alarm state machine covered by deterministic simulation tests including reboot, clock jump, call interruption, and force-quit; a physical-device reliability suite runs nightly across a real overnight schedule |

---

## 11. Telemetry (opt-in, aggregate only)

Tracked: delivery rate by tier, outcome distribution, time-to-complete by mission and difficulty, failure reasons by mission, permission grant/deny rates, watchdog activation rate, mission adoption and switching, crash-free alarm sessions.

**Never tracked:** images, raw sensor traces, alarm names, mission answers, location.

---

## 12. Edge Case Matrix

| # | Scenario | Required behavior |
|---|----------|-------------------|
| E1 | Alarm fires while user is in another app | System alert takes over; mission reachable in one tap |
| E2 | Music/podcast playing at ring time | Alarm interrupts; media is not auto-resumed |
| E3 | Headphones connected, not worn | Alarm plays on built-in speaker as well (INT-8) |
| E4 | Headphones unplugged mid-alarm | Re-routes within 1s; alarm never stops |
| E5 | Phone on Silent | Tier 1 rings; Tier 2/3 warned in advance |
| E6 | Focus / Sleep Focus active | Tier 1 rings |
| E7 | Call at the exact ring instant | `RINGING (audio suppressed)`, never `MISSED` |
| E8 | Call starts after alarm begins | Alarm state preserved; not auto-resolved |
| E9 | Call ends while alarm active | Re-presents within 2s |
| E10 | Two alarms within 90s | Merged into one session, hardest mission (INT-12) |
| E11 | Two alarms > 90s apart | Strictly sequential; neither is swallowed |
| E12 | App force-quit mid-mission | Alarm unresolved; watchdog returns it |
| E13 | Phone locked mid-mission | Progress preserved; resumes on unlock |
| E14 | User swipes away from mission screen | Blocked in-app; watchdog covers OS-level exits |
| E15 | Device rebooted before alarm | Alarm survives; reconciliation on first launch |
| E16 | Device off through the alarm time | Missed-window rule applies (TIM-7) and is disclosed |
| E17 | Low Power Mode enabled | Delivery unaffected; sensor warning shown |
| E18 | Time zone changed overnight | Wall-clock alarms hold local time; single notice; no duplicates |
| E19 | DST spring-forward onto a non-existent time | Fires at the next valid instant |
| E20 | DST fall-back onto a duplicated time | Fires once |
| E21 | User sets the clock forward to skip the alarm | Monotonic clock prevents skipping (MSN-INT-4) |
| E22 | Camera permission denied at ring time | Substitutes fallback mission; explains why (PRM-5) |
| E23 | Motion permission denied | Steps/squat unavailable; offers Shake/Math |
| E24 | Notifications disabled entirely | Blocking red banner; alarm reliability claim withdrawn |
| E25 | AlarmKit authorization revoked | Drops to Tier 2 with persistent warning |
| E26 | 50 consecutive failed math answers | New problem every time; no crash, no lock-out, no auto-dismiss |
| E27 | Photo target changed (room repainted) | Explicit failure reason + re-register flow + fallback offer |
| E28 | Rephotographing a screen showing the target | Rejected by liveness/screen heuristics with a clear reason |
| E29 | Steps banked before the alarm | Not counted — live streaming only |
| E30 | Phone shaken by hand during a step mission | Rejected by gait cross-check |
| E31 | Sync conflict on the same alarm | Conflict card; user chooses; nothing overwritten (DAT-5) |
| E32 | Sync service unreachable | Alarms unaffected (DAT-3) |
| E33 | Storage full | Alarm scheduling still succeeds; history writes degrade with a warning |
| E34 | Device detected as in-vehicle at ring time | Physical/camera missions suspended (SAF-3) |
| E35 | 100 alarms scheduled | Scheduling budget prioritization applies (REL-3) |

---

## 13. Release Plan

| Phase | Scope |
|-------|-------|
| **v1.0 — Reliability core** | ALM, REL (Tier 1 + Mission Guard), RNG, SNZ, SND, PRM, HIS-1/2/3, SET, TIM, missions M-00/01/02/03/04/05/06/09, local-only data, privacy, safety, full-free positioning |
| **v1.1 — Physical & visual** | M-07 Squat, M-08 Photo, M-10 Combination, Live Activity progress (RNG-6), practice mode |
| **v1.2 — Insight** | Streaks, statistics, history export, mission recommendations |
| **v1.3 — Continuity** | iCloud sync with field-level conflict resolution, Apple Watch companion, widgets |

**v1.0 ships only if the nightly physical-device reliability suite holds ≥99.9% across a 30-day run.** No feature is traded against that gate.

---

## 14. Open Questions

| # | Question | Owner | Impact |
|---|----------|-------|--------|
| Q1 | Minimum deployment target — iOS 26 only (clean, reliable, smaller market) vs iOS 18+ with a knowingly weaker Tier 2/3 path? **Recommendation: iOS 26.** | Product + Eng | High |
| Q2 | Does AlarmKit impose an undocumented cap on pending alarms per app? Determines the watchdog chain length and the alarm soft cap. | Eng (empirical) | High |
| Q3 | Should Alarmy apply for Critical Alerts as a Tier 2 reinforcement, accepting likely denial? | Product | Low |
| Q4 | Accessible completion path for Squat and Photo missions for users who cannot perform them — auto-substitute, or require explicit configuration? | Design + Accessibility | Medium |
| Q5 | Is the 90-second overlap-merge window right, or should it be user-configurable? | Product | Low |
| Q6 | If all missions are free, what funds development — optional cosmetic IAP, one-time unlock for sync, or ads outside the alarm path (ads in the wake-up flow are rejected outright)? | Business | High |
| Q7 | Should Mission Guard default to ON for first-time users, or be introduced after the first `DISMISSED_UNVERIFIED` event? | Product + Design | Medium |

---

## 15. Requirements Traceability (SRS → PRD)

| SRS topic | PRD requirements |
|-----------|------------------|
| Alarm CRUD, naming, toggle, duplicate, active display, next alarm | ALM-1 … ALM-12 |
| Works when app closed / locked / offline / device-scheduled | §6.1, §6.3, REL-9, REL-10, RNG-4 |
| Sound selection, vibration, loud & obvious, preview | SND-1 … SND-7, RNG-1 … RNG-3 |
| Other apps, media, headphones/Bluetooth, silent/DND | INT-7 … INT-11, E1–E6 |
| Calls, VoIP, call-timing permutations, no audio override | INT-1 … INT-6, N1, E7–E9 |
| Overlapping alarms & overlap rule | INT-12, E10, E11 |
| Snooze duration, availability, not-completion | SNZ-1 … SNZ-8, MEN-1 |
| Hard to dismiss half-asleep; challenge variety; per-alarm choice; difficulty | §6.2, MSN catalogue, MEN-1 … MEN-7, SET-4 |
| Math / walking / shaking / photo missions + anti-cheat | M-01, M-05, M-06, M-08, MSN-INT-1 … 7 |
| Missing Symbol / Memory / Typing / QR / Squat / Combination | M-02, M-03, M-04, M-09, M-07, M-10 |
| Permission fallbacks, no unnecessary permissions, explanations | PRM-1 … PRM-7 |
| Opening app ≠ completion; incorrect attempts; repeated failures; app closed/locked/navigated away | MEN-2, MEN-4, MSN-INT-1, MSN-INT-5, MSN-INT-6, E12–E14 |
| Reboot, battery restrictions, device-restriction disclosure, no "keep app open" | REL-4 … REL-8, E15, E17 |
| History, streaks, statistics, understandable not overwhelming | HIS-1 … HIS-8 |
| Defaults, remembered preferences, global defaults | SET-1 … SET-6 |
| Time zones, DST, no duplicates, passed-time alarms, disclosure | TIM-1 … TIM-8, E18–E20 |
| Degrade gracefully; cross-platform parity; explicit platform limits | §6.3, N4, PRM-5, P6 |
| Reliability over polish; difficult but not dangerous | P1, SAF-1 … SAF-5 |
| Offline data, sync failure tolerance, restore, conflicts, account deletion | DAT-1 … DAT-7, E31, E32 |
| Data disclosure, retention minimization, user control | PRV-1 … PRV-7 |
| Not punishing; fast to understand; obvious action; escalating difficulty | P2, G4, RNG-5, REL-2, UX-6, UX-7 |
| Layered anti-cheat; deliberate defeat attempts | P5, MSN-INT-2, MSN-INT-3, E21, E28–E30 |
| Dismissed vs completed vs never handled | MEN-1, §7.6.1 |
| All missions free; no visible-but-locked; complete toolkit | MON-1 … MON-5, G3, P7 |
| Progress display, immediate feedback, completion clarity, discovery | UX-1 … UX-5 |
| Mission difficulty & permission indication in the picker | UX-9, PRM-6 |
| Expandable mission library | MEN-7 |
| Sensor/permission unavailable → offer another mission | PRM-5, PRM-7, E22, E23 |

---

## 16. Appendix — Apple Constraints Cheat Sheet

| Constraint | Consequence for Alarmy |
|-----------|------------------------|
| AlarmKit alert always shows Stop | Mission Guard watchdog chain (§6.2) is mandatory, not optional |
| `NSAlarmKitUsageDescription` required | Ship copy: "Alarmy needs alarm access so your alarm can ring even when your phone is silent." |
| Custom alarm sound ≤30s, bundled | Sound library is local; no streaming at ring time |
| Live Activity unavailable before first unlock post-reboot | Alarm must be fully functional with system UI alone |
| Third-party apps cannot seize call audio | INT-1 … INT-6 design; explicit non-goal N1 |
| Critical Alerts entitlement rarely granted to alarm apps | Never a dependency (N2) |
| No guaranteed background execution | Watchdogs are **pre-scheduled**, never re-armed reactively |
| App Switcher / Control Center cannot be blocked | Integrity comes from unresolved-alarm semantics, not UI trapping |
| Max 64 pending local notifications | Constrains Tier 2/3 chain length |
| Photo library access is not required for the Photo mission | Camera-only capture strengthens anti-replay and reduces permissions |

---

*This PRD is derived from `SRS ALARMY.txt`. Every SRS statement maps to at least one requirement in §15. Where the SRS asks for behavior iOS does not permit, the PRD states the limitation explicitly and defines the closest permitted behavior — per the SRS's own instruction that platform limitations be handled rather than pretended away.*
