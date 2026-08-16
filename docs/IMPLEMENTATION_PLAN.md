# Implementation plan — red-team recommendations & iOS capabilities

Sequenced plan for the work [`RED_TEAM.md`](RED_TEAM.md) recorded as *recommended,
not done* (R1–R9) plus the iOS capabilities scoped out of that pass. Ordered by
dependency first and value second, because two of these items are genuinely
blocking for the rest and doing them late means doing some of them twice.

Each item states what it changes, how it is **verified**, and whether it can be
done in a cloud session or needs a Mac.

## Status

| Item | State |
|---|---|
| 1.1 Swift 6 language mode + `@MainActor` | **Done** |
| 1.2 Record → App Group container | **Done** |
| 2.1 Dew point clamp | **Done — finding withdrawn as wrong** |
| 2.2 Undo stack | **Done** |
| 2.3 Edit-sheet future timestamps | **Done** |
| 2.4 `ZipArchive` bounds | **Done** |
| 2.5 Lazy model construction | **Superseded** — see below |
| 2.6 Dynamic Type on readouts | **Done** (needs a visual pass on a device) |
| 2.7 Backup disclosure | **Done** |
| 3.1 Haptics | **Done** |
| 3.2 Obs cadence notifications | **Done** (delivery needs a device) |
| 3.3 App Intents / Siri / Shortcuts | **Done** (Siri phrasing needs a device) |
| 3.4 WidgetKit + Live Activity | **Done** — all 15 tasks landed (widget, Live Activity, CI schemes); rendering and Activity lifecycle still need the device checklist in [`PLAN_WIDGET_AND_WATCH.md`](PLAN_WIDGET_AND_WATCH.md) |
| 3.5 watchOS app | **Done (read-only)** — watch app + complication landed with 3.4; compiles and is CI-covered, behaviour unverified on a paired watch. See [`PLAN_WIDGET_AND_WATCH.md`](PLAN_WIDGET_AND_WATCH.md) |

A **Swift 6.1 toolchain became available** in the authoring environment partway
through, so core work is now verified locally (`swift test`, vector regeneration,
the parity harness) rather than only through CI. That is what turned 2.1 from an
hour of Mac-only work into a five-minute proof that the finding was wrong.

**2.5 is superseded.** The cost it named — `RootView.init` JSON-decoding the whole
shift and history on every re-initialization and discarding it — was a property of
the `UserDefaults` blobs. With 1.2 landed, construction reads two files through
`ObservationRecordStore` and the expensive decode is gone. Re-measure before doing
anything further; there may be nothing left to fix.

**3.4 and 3.5 now have their own task-level plan** in
[`PLAN_WIDGET_AND_WATCH.md`](PLAN_WIDGET_AND_WATCH.md), written after a design
review that settled the **display policy** both depend on (now recorded as a
guardrail in `CLAUDE.md`). Two consequences changed the shape of the work:

- The widget's staleness rule became a pure `ObsGlance` type in `PlateworksCore`,
  golden-tested on Linux CI, rather than untested logic inside an extension.
- The watch app is read-only **by policy, not by scoping** — freezing a reading
  requires the capture card — so the two-way `WatchConnectivity` merge problem
  that dominated the original estimate is gone entirely.

**3.4 and 3.5 have since landed** (all 15 tasks of the task-level plan; widget,
Live Activity, and read-only watch targets, CI-covered). What remains is the
**device checklist** in `PLAN_WIDGET_AND_WATCH.md` — the behaviour that can only
be judged on hardware: the widget's refresh cadence and staleness presentation,
the Live Activity lifecycle, the complication, and `WatchConnectivity` sync.
Treat that checklist as the release gate for these surfaces; the reasoning below
about why device verification matters for a safety-relevant app stands. 1.2 did
the hard part of the widget's dependency in advance: the record is in an App
Group container, so the extension reads it without a second migration.

---

## What changed about what's plannable

Two things from the red-team pass move items that were previously "you'd have to
hand-test this" into "CI can prove it":

1. **The app target now builds and tests in CI** (`app-build` job: XcodeGen →
   iOS Simulator + macOS → both test bundles). Before, `App/` was never compiled
   by anything.
2. **`PlateworksIgnitionTests` runs for the first time**, and it already has the
   exact fixture pattern the riskiest item needs:

   ```swift
   private func fresh(_ name: String) -> UserDefaults {
       let d = UserDefaults(suiteName: "test.\(name)")!
       d.removePersistentDomain(forName: "test.\(name)")
       return d
   }
   ```

   That is a seam for **round-trip migration tests**: seed a store in the *old*
   format, construct the model, assert the record survives byte-for-byte. R1 was
   declined during the red-team pass specifically because a storage migration
   can't be pushed on faith — with the app bundle now executing in CI, it can be
   proven rather than hoped.

---

## Two sequencing constraints worth respecting

**A. Storage and the widget/watch work are coupled — do the migration once.**

R1 (get the growing observation record out of `UserDefaults`) has an obvious
shape: atomic file writes under Application Support. But a **widget extension is
a separate process and cannot read the app's private container** — it needs an
App Group. If R1 lands as a plain Application Support write and WidgetKit arrives
later, the record gets migrated *twice*, and each migration of a live shift log
is a chance to lose one.

So: R1 writes into an **App Group container from the start**
(`group.org.plateworks.ignition`), whether or not a widget exists yet. One
migration, one risk window.

> Note the limit of that: App Groups share between an iOS app and its extensions
> on the *same device*. They do **not** reach a paired watch. An independent
> watchOS app has its own storage, so the watch needs `WatchConnectivity`
> (`WCSession`) regardless — plan 3.5 accordingly and don't assume the App Group
> covers it.

**B. Language mode before new targets.**

R4 (`@MainActor` on the models, Swift 6 language mode for the core) should land
before any new target is written. New targets are written in whatever mode is
current and all of them link `PlateworksCore`; converting three models plus a
widget, an intents extension, and a watch app is strictly worse than converting
three models.

```
R4 (concurrency) ─┬─► 3.3 App Intents
                  ├─► 3.4 Widgets + Live Activity
R1 (App Group) ───┴─► 3.5 watchOS app ──► (WatchConnectivity, not App Group)

R6 (dew point) ───► independent, but the only item touching the parity machinery
Everything in Phase 2 ───► independent of each other; parallelizable
```

---

## Phase 1 — Foundations

Blocking for Phase 3. Both are refactors with no user-visible change, which makes
them the right things to do while the test suite is fresh in mind.

### 1.1 Swift 6 language mode + `@MainActor` on the models (R4)

**Change.** Annotate `IgnitionModel`, `HumidityModel`, `WeatherWatchModel`, and
`SiteLocationProvider` `@MainActor`; move `PlateworksCore` to
`swiftLanguageModes(.v6)` in `Package.swift`; resolve whatever falls out.

**Why it's not just hygiene.** The models are mutated from views and read from
`pendingObs` with no isolation. It compiles today only because the package is in
Swift 5 mode. The core types are already `Sendable`, so the core is close to
ready; the app layer is where the work is. Expect friction at
`@State private var x = Model()` (a main-actor init from a view's synthesized
init) and at the `SiteLocationProvider` delegate hop — the latter is already
written to survive this (see its type comment).

**Verification.** Entirely CI: the Linux job proves the core under the new mode,
the app job proves the app layer. This is the single most CI-provable item on the
list.

**Size.** Half a day. **Risk.** Low — compile-time only, no behavior change.
**Environment.** Cloud session is fine.

### 1.2 Observation record → App Group container, atomic writes, migration (R1)

**Change.** Move `watch.shift` and `watch.history` out of `UserDefaults` into JSON
files in an App Group container, written with `Data.write(to:options: .atomic)`
and an appropriate `FileProtectionType`. Small scalar preferences stay in
`UserDefaults`. Add `group.org.plateworks.ignition` to `project.yml` entitlements.

**Why.** `UserDefaults` is a preferences cache read and written wholesale as a
plist. `history` is *designed* to grow across a whole assignment, and every
appended observation re-encodes and rewrites the entire structure. It is also the
evidentiary record of what went out over the radio net.

**Verification — this is the part that matters.** Do not ship this on a green
compile:
- Round-trip migration test in `PlateworksIgnitionTests`: seed a store in the old
  `UserDefaults` format (multi-day history, obs with frozen `broadcastText`,
  pre-feature obs with `nil` optionals), construct `WeatherWatchModel`, assert
  every observation survives identically — including `broadcastText`, which must
  never be re-rendered by a migration.
- Idempotence test: run the migration twice, assert no duplication and no loss.
- Partial-write test: assert a half-written file leaves the previous good file
  intact (that's what `.atomic` buys, and it should be pinned).
- Keep the old keys readable for at least one release; don't delete on first
  successful migration.

**Size.** 1–2 days including tests. **Risk.** Highest item in this document — a
migration that silently drops a shift log is worse than the problem it fixes.
**Environment.** Writable in a cloud session because the tests are real, but
**verify on a device with a real multi-day record before release.**

---

## Phase 2 — Correctness and ergonomics debt

Independent of each other and of Phase 1. Can be done in any order, or batched.

### 2.1 Dew point clamp (R6) — **done: the finding was withdrawn**

The premise was wrong. The dew point provably cannot exceed the dry bulb (the
wet bulb is already clamped, saturation vapor pressure is monotonic, and the
subtracted psychrometer term is non-negative), verified by sweeping the whole
10–130 °F input space across all six bands: maximum excess is exactly zero.

What was actually wrong was the test's `dry + 1` tolerance, which made the
invariant look uncertain. Tightened to assert exactly, over the full range and
every band. No clamp added — an unreachable one would mask a future break in the
wet-bulb clamp rather than let the test catch it.

Consequences for this plan: **vectors did not move**, `web/engine.js` needed no
port, and no service-worker cache bump was required. The item that was sized at
"an hour, needs a Mac" cost a test edit and no parity work at all. See
`RED_TEAM.md` R6 for the full argument.

### 2.2 Undo stack for deleted observations (R3)

`removeObs` overwrites `lastRemovedObs` while the undo strip still reads
"Observation removed", so after two deletes the first is unrecoverable with no
indication. Either keep a small bounded stack or dismiss the strip when it goes
stale. Testable in `PlateworksIgnitionTests` alongside the existing
`testUndoRestoresDeletedObs`. **Size.** 2 hours. **Environment.** Cloud.

### 2.3 Future-dated timestamps in the edit sheet (R7)

The future-time caution added to the capture card doesn't cover `ObsEditSheet`,
which can still move a logged observation's timestamp forward. Same class as the
log-bar bug already fixed; apply the same guard. **Size.** 1 hour.
**Environment.** Cloud.

### 2.4 `ZipArchive` bounds (R8)

`UInt16(name.count)` / `UInt32(bytes.count)` trap rather than error on overflow.
Unreachable with current inputs; make it a thrown error or a documented
precondition so it fails rather than crashes if that changes. **Size.** 1 hour.
**Environment.** Cloud (core, Linux-tested).

### 2.5 Lazy model construction in `RootView` (R2)

`State(initialValue:)` is not lazy, so every `RootView` re-initialization runs
`IgnitionModel()` and `WeatherWatchModel()` — the latter JSON-decoding the entire
shift and history — and discards the result. Impact is small today and grows with
the record; **note it shrinks on its own once 1.2 lands** and decoding moves
behind file I/O that can be made lazy. Worth doing *after* 1.2, not before.
**Size.** 1 hour. **Environment.** Cloud.

### 2.6 Dynamic Type on the primary readouts (R5)

`PlateworksFont.readout(_:)`, `.inputValue` (32 pt) and `.title` (22 pt) are fixed
point sizes, so the numbers a crew actually reads — at arm's length, in smoke,
possibly without reading glasses — don't respond to the accessibility text size
they set. `StatusStrip` and `ResultCard` already do this correctly with
`@ScaledMetric`; extend the same approach to the readouts.

**Verification.** This is the one item CI genuinely cannot judge. Needs visual
checking at the larger accessibility sizes to confirm the result cards don't clip
or reflow badly — `ResultCard`'s fixed-height caption slot exists precisely to
stop input-driven jitter, and that interacts with scaled text.
**Size.** Half a day including the visual pass. **Environment.** **Needs a Mac**
(Xcode previews at accessibility sizes, ideally a device).

### 2.7 Backup disclosure wording (R9)

Documentation only. The privacy posture is accurate; the precise statement is
that `UserDefaults` — and, after 1.2, the App Group container — is included in
iCloud and encrypted local backups, so the record including GPS coordinates does
leave the device that way. Ordinary iOS behavior, not developer collection, but
"the data never leaves the phone" is a stronger claim than the truth. Align
`PrivacyInfo.xcprivacy` commentary, `docs/APP_STORE.md`, and the web privacy copy.
Consider whether the observation log should set `isExcludedFromBackup` — probably
**not**, since losing a shift record to a phone replacement is worse.
**Size.** 1 hour. **Environment.** Cloud.

---

## Phase 3 — iOS capabilities

Ordered by value per unit of work. Everything here depends on Phase 1.

### 3.1 Haptics on log / delete

`.sensoryFeedback(.success, trigger:)` on a successful log, `.warning` on delete.
Confirms a gloved tap without looking at the screen. **Size.** 1 hour.
**Risk.** None. Do it first — it's the cheapest real field improvement here.

### 3.2 Obs cadence local notifications

The "next obs due" countdown only works while the app is foregrounded, which
undercuts the point: a weather watch is a *prospective* discipline. Schedule a
`UNTimeIntervalNotificationTrigger` off the last logged observation; reschedule on
log, edit, delete, and new shift; cancel when a shift ends.

Design care: the notification must be **advisory, not authoritative** — it should
say an obs is due, never quote a PIG, because a PIG in a notification is a
computed value presented outside the disclaimer context. Ask permission at the
point of value (first log), not at launch.

**Verification.** Scheduling logic belongs in a testable type
(`ObsCadenceScheduler`) so `PlateworksIgnitionTests` covers "log at 1400 → next
notification at 1500", with the `UNUserNotificationCenter` call behind a protocol.
Delivery itself needs a device. **Size.** 1 day. **Environment.** Mostly cloud;
device check before release.

### 3.3 App Intents / Siri / Shortcuts / Control Center

Expose "log a weather observation" and "what's the current PIG" as `AppIntent`s.
That reaches Siri, Shortcuts, the Action Button, and — gated `if #available(iOS 18)`
— a Control Center control. Hands-free matches the actual posture on a line.

Depends on 1.1: intents run in a separate process context and are written against
strict concurrency. The "log" intent also needs the shared record from 1.2 if it
is to work without launching the app.

**Size.** 1–2 days. **Environment.** Cloud for the intent definitions; device for
Siri phrasing and the Action Button.

### 3.4 WidgetKit + Live Activity

Lock/home-screen widget showing the latest PIG and fire-behavior band; a Live
Activity counting down to the next obs. **Hard dependency on 1.2** — a widget
extension cannot read the app's private container.

Design care: a widget shows a **frozen, timestamped** reading. It must carry its
observation time prominently, because a stale PIG presented as current is exactly
the failure this repo exists to prevent — the same reasoning behind the existing
weather-freshness strip.

**Size.** 2–3 days. **Environment.** Device for real widget behavior.

### 3.5 watchOS app

`Package.swift` already declares `.watchOS(.v10)` with **no watch target** — the
platform is claimed but not shipped, which is worth resolving one way or the other
(build it, or drop the declaration).

A wrist readout is close to ideal for this job, and `PlateworksCore` is already
portable. The real work is the data path: an independent watchOS app has its own
storage, so **App Groups do not help** — syncing the shift log needs
`WatchConnectivity` (`WCSession`), with a decision about whether the watch is
read-only (mirror the current reading) or can log observations, which makes it a
two-way merge problem.

**Recommendation:** ship it read-only first. A wrist glance at current PIG and
next-obs-due is most of the value at a fraction of the risk; two-way logging can
follow if crews ask for it.

**Size.** 3–5 days read-only; considerably more for two-way. **Environment.**
Needs a Mac and a paired watch.

---

## Environment split

The single largest constraint on who can do what.

| Can be done in a cloud session (CI proves it) | Needs a Mac / device |
|---|---|
| 1.1 Swift 6 + `@MainActor` | 2.1 dew point — **needs a Swift toolchain for vector regen** |
| 1.2 storage migration (tests are real; device-check before release) | 2.6 Dynamic Type — visual judgment |
| 2.2 undo stack · 2.3 edit-sheet timestamps · 2.4 zip bounds · 2.5 lazy models · 2.7 disclosure | 3.4 widgets · 3.5 watchOS |
| 3.1 haptics · 3.2 scheduler logic · 3.3 intent definitions | Siri phrasing, Action Button, notification delivery |

---

## Suggested order

1. **1.1** (foundations, most CI-provable, unblocks Phase 3)
2. **2.1** next time a Swift toolchain is available — it's an hour and clears the
   only parity-touching debt
3. **1.2** (the big one; do it while the test suite is fresh)
4. **2.2 / 2.3 / 2.4 / 2.5 / 2.7** as a batch — small, independent, low risk
5. **3.1**, then **3.2**
6. **2.6** on the next Mac session, alongside a general accessibility pass
7. **3.3**, then **3.4**
8. **3.5** last, read-only first

Against the charter's milestones: everything through step 5 is reasonable
**pre-TestFlight**. Steps 6–7 fit between TestFlight and App Store review — 2.6
in particular should land before review, since accessibility is something review
does look at. 3.5 is comfortably post-1.0.
