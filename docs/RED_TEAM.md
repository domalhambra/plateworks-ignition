# Red team — Badwater Ignition

A hostile read of the codebase, ranked by what it would cost a crew on a line.
Findings are grouped by whether they were fixed in the pass that produced this
document or left as recommendations with reasons.

The lens throughout: **this app's output is a number someone acts on.** A crash
is an inconvenience; a PIG that is quietly wrong, or a record that quietly isn't
saved, is the failure mode the repo exists to prevent. Findings are ranked by
that, not by how exotic they are.

Positions are given as file + symbol rather than line numbers, which drift.

---

## The headline: nothing verified the app

The largest finding was not in the code.

`.github/workflows/ci.yml` ran two jobs — the Linux `BadwaterCore` suite and the
Node parity harness — and **neither one compiled `App/`.** The SwiftUI target,
the entire presentation layer of a safety-relevant App Store candidate, had no CI
of any kind. `BadwaterIgnitionTests` and `BadwaterIgnitionUITests` both existed,
both were substantial, and neither had ever executed.

Adding a `macos-15` job that builds and tests the app target found three real
defects within minutes, each of which had been sitting in `main`:

| Found by the new job | Severity |
|---|---|
| `BadwaterIgnitionTests` could not launch at all — `TEST_HOST` never resolved | High |
| `BadwaterIgnitionUITests` — 5 of 6 tests fail; the suite has never passed | High |
| A stray brace from this PR's own refactor (caught immediately) | — |

The core was fine: `BadwaterCore` was already well-tested, well-documented, and
Linux-verified, and the parity machinery around it is genuinely good. The gap was
entirely on the app side, and it was invisible precisely because nothing looked.

---

## Fixed in this pass

### 1. The observation timestamp did not track the wall clock — High, affects PIG

`WatchView.pendingTime` was seeded once when the view was constructed and never
moved again except by a log. An app opened at 0900 and returned to at 1400
stamped the observation **0900**.

That is not a cosmetic timestamp error. `WeatherWatchModel.pendingObs(at:)`
derives both the month and the IRPG time-of-day band *from that timestamp*, so
the reading was filed under the wrong correction column in Table B/C/D and
produced a wrong Fine Fuel Moisture and a wrong Probability of Ignition. The
0800–1959 daytime bands and the night "+5" rule are different calculations
entirely — a stale timestamp can silently move a reading between them.

Fixed: the time re-seeds on tick, on appear, and on foreground unless the
operator has taken it over by typing or nudging.

> Sharp edge worth recording: detecting "the operator took it over" by exact
> `Date` equality does **not** work. `ObsTimeField` echoes the value back through
> its `"HH:MM"` text field, and that round trip zeroes the seconds — so the echo
> reads as a manual edit and tracking stops one tick after the view appears,
> reintroducing the bug. The comparison is at minute granularity for that reason.

### 2. Logging forward-dated the next observation — Medium-high

After a log, `pendingTime` was advanced by one hour to "pre-fill the next hourly
slot". That writes a *future* timestamp into the pending obs. A second tap — a
gloved double-tap, a correction, a back-fill — logged an observation that had not
happened yet, and `obsDueStrip` then counted down from a `latest.timestamp` in
the future, so the cadence annunciator stopped telling the truth.

Fixed: logging hands the time back to the clock. Announcing when the next obs is
due is the due strip's job, not the timestamp's. A hand-set future time now
raises a caution with a "Use now" action.

### 3. Silent loss of the observation record — Medium (latent, catastrophic)

`WeatherWatchModel.persistShift()` / `persistHistory()`:

```swift
store.set(try? JSONEncoder().encode(shift), forKey: Keys.shift)
```

`try?` yields `nil` on an encode failure, and `UserDefaults.set(nil, forKey:)`
**removes the key**. The write meant to save the log would erase it, the next
launch would decode a fresh empty `Shift`, and nothing would indicate anything
was lost — including to the crew whose broadcast record it was.

Honest severity: `Shift` has no throwing members today, so this is latent rather
than active. It is listed high anyway because the failure is total and silent,
the guard costs four lines, and the value being guarded is evidentiary.

Fixed: encode failures refuse to write, leave the previous stored copy intact,
and set `persistenceFailed`, which the screen surfaces as "export the spreadsheet
before you quit the app."

### 4. A below-sea-level site elevation could not be entered — Medium

The site elevation field used `.numberPad`, which has **no minus key**. Badwater
Basin — the feature the product is named after — is −282 ft. Any crew working
below sea level simply could not enter their elevation, and that field selects
the `ElevationBand` supplying station pressure for the wet-bulb RH derivation.

`ElevationBand.forElevation(feetMSL:)` explicitly handles negative elevations, so
the core was right and the keyboard was wrong. Fixed, and keyboards are now
chosen by capability (`FieldKeyboard`) so the next such choice is reviewable
rather than a bare UIKit enum case.

### 5. Coordinate entry discarded the saved position mid-edit — Medium

`commitCoordinate()` set `siteCoordinate = nil` whenever *either* field failed to
parse. Clearing longitude to retype one digit silently discarded the whole sticky
position. There was also no range validation — latitude `500` was accepted and
would be frozen onto observations and read out on the radio net.

Fixed: only clearing **both** fields clears the coordinate; partial or invalid
input leaves the last good position alone and says so. Range and finiteness
checks now live in `GeoPoint.isValid` / `init?(validating:longitude:)` in the
core, where they are tested.

### 6. Two always-on timers — Medium (battery is a safety input)

`WatchView` and `IgnitionView` each ran an autoconnected
`Timer.publish(...).autoconnect()` (30 s and 60 s). An autoconnected publisher
keeps a run-loop source alive for the whole life of the view — including while
its tab is off screen — and every tick re-evaluated the entire body. On `WatchView`
that body also re-ran `pendingObs()`, `broadcastScript()`, and `dayLines()`.

On a 16-hour shift with no way to charge, battery is not a performance concern.
Replaced with `.task` loops that cancel with the view.

### 7. The IMET workbook was rebuilt on every body pass — Low-medium

The `document:` argument of `.fileExporter` is evaluated on each `body`
evaluation, and it was constructing `IMETWorkbookDocument(data: model.imetWorkbookData())`
inline. With the export sheet open, the entire multi-day `.xlsx` — zip container,
CRC32 over every part, all sheets — was rebuilt every 30 seconds. Built once on
the tap instead.

### 8. Documentation described a feature that did not exist — Medium

`WeatherWatchModel.siteCoordinate` was documented as "typed or GPS-filled". There
was no CoreLocation anywhere in the repository. Crews were typing decimal degrees
into a text field on a fireline.

Fixed by building it: see **GPS site autofill** below.

### 9. GPS elevation rounding is not band-neutral — Medium (new code, contained)

Introduced and resolved within this pass, recorded because the reasoning is
load-bearing.

Rounding a GPS elevation to the nearest 100 ft is the right call — GPS vertical
accuracy is routinely ±10–50 m, so a raw `5657 ft` is false precision. But every
`ElevationBand` top (500, 1,900, 3,900, 6,100, 8,500 ft) is *itself* a multiple of
100, so a raw elevation 1–49 ft above one rounds **down** onto it and lands a band
low — a different station pressure, a different RH, a different PIG. There are 245
such elevations in field range.

Contained by an invariant rather than a special case: whenever rounding changes
the band, the rounded value is exactly a band top, so the straddle check flags it
for any positive uncertainty. `SiteElevation.effectiveUncertaintyFeet` floors the
sensor's stated accuracy at the ±50 ft the rounding itself introduces, which is
what makes that hold. `SiteElevationTests` pins both halves — that the 245 exist,
and that every one is flagged for map confirmation.

---

## Recommended, not done

> **Status audit, 2026-08-15.** Most of this section has since shipped. Each item
> below carries a **Status** line saying what landed and where; the original
> reasoning is left as written — it is the record of why the work was deferred at
> the time. Task-level status lives in
> [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md)'s Status table, which this
> audit confirmed against the code.

Each of these was deliberate. The authoring environment had **no Swift toolchain
and no Xcode**, so CI was the only verification available; changes whose risk
outweighs what CI can prove were written up rather than landed blind.

> **Sequenced plan for everything below — and for the iOS capabilities at the end
> of this document — is in [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md).**
> Two dependencies there are worth knowing before picking any item up: the
> storage move (R1) should target an App Group container from the start or the
> record gets migrated twice once widgets exist, and the concurrency work (R4)
> should precede any new target.

### R1. The observation record lives in `UserDefaults` — Medium

> **Status: done** (plan item 1.2). The record now lives as JSON files in the
> App Group container, written atomically through `ObservationRecordStore`
> (`App/PlateworksIgnition/Features/Watch/ObservationRecordStore.swift`), with
> the container/location logic in `App/Shared/RecordLocation.swift`. Scalar
> preferences stayed in `UserDefaults`. Targeting the App Group from the start
> means the widget/watch work needs no second migration.

`watch.shift` and `watch.history` are JSON blobs in `UserDefaults`, and `history`
is explicitly designed to grow across a whole assignment. Every append re-encodes
and rewrites the entire structure. `UserDefaults` is a preferences cache backed by
a plist read and written wholesale — not a datastore, and not where a growing
evidentiary record belongs.

**Recommendation:** move `shift` and `history` to atomic file writes
(`Data.write(to:options: .atomic)`) under Application Support with an appropriate
`FileProtectionType`, keeping `UserDefaults` for the small scalar preferences.
Needs a one-time migration on first launch.

**Why not now:** a storage migration that silently drops an existing shift log is
strictly worse than the problem it fixes, and a green compile is not evidence a
migration works. This wants a local toolchain and a device test.

### R2. `RootView.init` rebuilds every model on each re-initialization — Low-medium

> **Status: superseded** (plan item 2.5). `RootView.init` still uses
> `State(initialValue:)`, but the expensive part of the cost — JSON-decoding the
> entire shift and history out of `UserDefaults` on every re-initialization —
> went away with R1: construction now reads through `ObservationRecordStore`.
> Re-measure before doing anything further; there may be nothing left to fix.

`State(initialValue:)` is not lazy: the expression is evaluated on every `RootView`
initialization and the result discarded on all but the first. Each one runs
`IgnitionModel()` (14 `UserDefaults` reads) and `WeatherWatchModel()` — which
**JSON-decodes the entire shift and history**. Root views re-initialize rarely, so
impact is small today and grows with the record.

### R3. A second delete makes the first unrecoverable — Low

> **Status: done** (plan item 2.2). `WeatherWatchModel` now keeps a bounded
> undo stack (`removedObsStack`, depth `undoDepth = 10`) instead of the single
> `lastRemovedObs` slot; sequential deletes restore in reverse order.

`removeObs` overwrites `lastRemovedObs`, but the undo strip stays on screen saying
"Observation removed". After two deletes the strip offers to restore only the
second, with no indication the first is gone. Either keep a small undo stack or
dismiss the strip when it goes stale.

### R4. Models are not `@MainActor` — Low (forward-looking)

> **Status: done** (plan item 1.1). `Package.swift` is
> `swift-tools-version: 6.0`, every target in `project.yml` sets
> `SWIFT_VERSION: "6.0"`, and the models (`IgnitionModel`,
> `WeatherWatchModel`), `SiteLocationProvider`, and the app-layer views carry
> `@MainActor`. Landed before the App Intents / Live Activity / watch-sender
> targets were written, as the sequencing note above required.

The three `@Observable` models are mutated from views and read from `pendingObs`
with no actor isolation. The package is `swift-tools-version: 5.9` in Swift 5
language mode, so this compiles today; it will not under the Swift 6 language
mode. The core types are already `Sendable`, so annotating the models and moving
the core to `swiftLanguageModes(.v6)` is a contained piece of work.

### R5. The primary readouts don't scale with Dynamic Type — Low-medium

> **Status: done, pending a visual pass on a device** (plan item 2.6). The
> readout style is now `@ScaledMetric`-backed: see the scaling modifier
> `readout(_:weight:relativeTo:)` in
> `App/PlateworksIgnition/DesignSystem/Typography.swift`, scaled
> `relativeTo: .body` with a minimum-scale guard. The fixed-size
> `PlateworksFont.readout(_:)` remains only as the documented non-scaling
> primitive behind it.

`BadwaterFont.readout(_:)`, `.inputValue` (32 pt), and `.title` (22 pt) are fixed
point sizes. `StatusStrip` and `ResultCard` already do the right thing with
`@ScaledMetric`, and tap targets are generously sized for gloves — but the
numbers a crew actually reads, at arm's length, in smoke, possibly without
reading glasses, do not respond to the accessibility text size they set.

Worth treating as a field-ergonomics issue rather than a checkbox: relative
sizing (`Font.system(.largeTitle, design: .rounded)`) or `@ScaledMetric` on the
readout sizes, verified at the larger accessibility sizes so the result cards
don't clip.

### R6. Dew point is not clamped to the dry bulb — **WITHDRAWN, this finding was wrong**

> **Status: closed** (plan item 2.1). The test tightening described below is
> landed — `testDewPointNeverExceedsDryBulb` in
> `Tests/PlateworksCoreTests/PsychrometricsTests.swift` asserts the exact
> invariant. No clamp was added, deliberately; vectors did not move and no web
> port was needed.

**Original claim:** `Psychrometrics.compute` clamps RH to 100% but derives
`dewPointF` from the unclamped vapor pressure, so a saturated reading can report
a dew point a degree above the dry bulb.

**That cannot happen.** The dew point provably never exceeds the dry bulb:

- `wet` is already clamped to `≤ dryBulbF` at the top of `compute`;
- saturation vapor pressure is monotonic in temperature, so `esWet ≤ esDry`;
- the psychrometer term subtracted from it is non-negative, since `tDryC ≥ tWetC`.

Therefore `vaporPressure ≤ esWet ≤ esDry`, hence `dewPointC ≤ tDryC`. At
saturation the Bolton inversion returns the dry bulb *exactly* — algebraically,
the substitution cancels to `t`.

Confirmed empirically as well as algebraically: swept the entire 10–130 °F
dry-bulb × wet-bulb space across all six pressure bands, and the maximum value of
`dewPointF − dryBulbF` is exactly `0.000000000000`.

**What was actually wrong** was the test, not the code.
`testDewPointNeverExceedsDryBulb` asserted `dewPointF ≤ dry + 1`, and that
one-degree tolerance is what made the invariant look uncertain. It has been
tightened to assert equality-or-less **exactly**, across the full input range and
every band, including wet bulbs above the dry bulb so the saturation edge is
covered.

No clamp was added, deliberately. An unreachable `min(dewPoint, dryBulb)` would
be untested code in a safety-relevant path, and worse, it would *mask* a future
break in the wet-bulb clamp instead of letting the test fail loudly.

Cost of the original error: it was sized at "an hour, needs a Mac for vector
regeneration". The real fix was a test tightening with no vector movement at all.

### R7. `ObsEditSheet` can still set a logged obs into the future — Low

> **Status: done** (plan item 2.3). Capture and edit were unified into
> `ObsFormSheet` (`App/PlateworksIgnition/Features/Watch/ObsFormSheet.swift`),
> whose `futureTimeStrip` covers both modes — the edit path flags a
> forward-dated timestamp (`edit-time-future`) with the same caution and
> "Use now" action as the capture card. `ObsEditSheet` no longer exists as a
> separate view.

The future-time caution added to the capture card doesn't cover the edit sheet,
which can move a logged observation's timestamp forward. Same class as finding 2.

### R8. `ZipArchive` traps on oversized entries — Low

> **Status: done** (plan item 2.4). `ZipArchive` now declares its classic-ZIP
> `Limit`s and a `Failure` error; `zipChecked(_:)` throws a diagnosable error
> instead of trapping, and the non-throwing `zip(_:)` wrapper is a documented
> precondition for the in-app workbook whose inputs cannot violate the limits.

`UInt16(name.count)` and `UInt32(bytes.count)` trap rather than error on overflow.
Unreachable with current inputs (a few kilobytes of sheet XML, short paths), but
it is a crash rather than a failure if that ever changes.

### R9. The record is included in device backups — Informational

> **Status: done** (plan item 2.7). The precise statement is recorded in the
> commentary of `App/PlateworksIgnition/PrivacyInfo.xcprivacy`, including the
> deliberate decision **not** to set `isExcludedFromBackup` (losing a shift
> record to a phone replacement is the worse outcome). `docs/APP_STORE.md` and
> the web copy make no "never leaves the device" claim, so nothing there needed
> weakening.

The privacy posture ("all compute on-device, no data collection") is accurate and
well-evidenced. Worth stating precisely though: `UserDefaults` is included in
iCloud and encrypted local backups, so the observation log — including GPS
coordinates — does leave the device that way. That is ordinary iOS behavior and
not collection by the developer, but it is a different claim from "the data never
leaves the phone."

---

## GPS site autofill — what shipped

Built this pass, scoped to what a crew needs at the point of entry.

- **One-shot, never continuous.** `SiteLocationProvider` calls `requestLocation()`
  for a single fix. A weather watch needs the site's position, which changes when
  the crew moves — not a live track that would drain battery all shift and keep a
  location stream running in a tool whose premise is that it observes nothing.
- **Elevation rounded to 100 ft**, via `SiteElevation` in the core, where it is
  tested on Linux CI.
- **Band-edge honesty.** A fix whose uncertainty spans two elevation bands says so
  and asks for map confirmation, rather than being trusted silently into the RH
  derivation.
- **Manual override is the same fields, not a mode.** There is nothing to unlock.
  Any hand edit to the elevation or either coordinate flips `siteSource` back to
  `.manual` and drops the fix provenance; the caption shows `GPS · 14:32` or
  `Entered by hand` so a GPS fill is never mistaken for a surveyed value.
- **Degrades rather than blocks.** Denied permission, no vertical component, or no
  fix at all each produce a message and leave the typed fields fully usable. A
  coordinate-only fix does not blank a previously entered elevation.

---

## iOS capabilities not built this pass

Scoped out deliberately; recorded so the reasoning survives. Roughly in order of
value per unit of work for this app:

| Capability | Why it fits | Notes |
|---|---|---|
| **Local notifications for the obs cadence** | The "next obs due" countdown only works while the app is foregrounded. A weather watch is a *prospective* discipline; a notification is the right primitive for it. | `UNUserNotificationCenter`, scheduled off the last logged obs. Small. |
| **Haptics on log / delete** | Confirms a gloved tap without looking at the screen. | `.sensoryFeedback` — very small. |
| **watchOS app** | A wrist readout is close to ideal for this job. Note `Package.swift` already declares `.watchOS(.v10)` with **no watch target** — the platform is claimed but not shipped. | Largest item here. |
| **App Intents / Siri / Shortcuts / Action Button** | "Log a weather obs" hands-free, which is the actual posture on a line. | Also unlocks a Control Center control on iOS 18+. |
| **WidgetKit + Live Activity** | Latest PIG and fire-behavior band on the lock screen; obs countdown in the Dynamic Island. | Most new surface area to maintain. |

One constraint worth keeping in view: the deployment target is iOS 17, which is
several majors back — appropriate for field hardware that doesn't get replaced on
Apple's schedule. Anything above it needs `if #available` gating rather than a
bump.
