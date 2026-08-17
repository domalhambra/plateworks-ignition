# CLAUDE.md — Badwater Ignition

Operator manual for Claude. Human entry point is `README.md`; project vision, status, and milestones are in `PROJECT_CHARTER.md`.

## What this project is

A fast, offline field calculator for wildland firefighters: **Probability of Ignition (PIG)**, **Fine Fuel Moisture (FFM)**, and **relative humidity**, computed cell-for-cell from the NWCG *Incident Response Pocket Guide* (IRPG, PMS 461) and belt-weather-kit tables. It ships twice from one repo:

- a **native SwiftUI app** (iOS/macOS) in `App/PlateworksIgnition/` — in development toward an App Store release, and
- a **static, offline-first web PWA** in `web/`, live at **ignition.plateworks.org**.

This is the only **safety-relevant** Badwater property. A wrong PIG on either platform is exactly the bug this repo exists to prevent, so fidelity to the printed guide is non-negotiable and correctness discipline (below) is not optional.

## Source-of-truth boundary

| Domain | Source of truth |
|---|---|
| All calculation logic | **`Sources/PlateworksCore/`** — pure Swift, no UI, no Apple-framework deps, Linux-testable. This is the truth. |
| Native UI | `App/PlateworksIgnition/` (SwiftUI, generated via XcodeGen from `project.yml`) |
| Web calculation | `web/engine.js` — a hand-written **JS twin of `PlateworksCore`**. Never the source; always the port. |
| Web UI | `web/app.js` (twin of `App/`) + `web/index.html` |
| IRPG table values | cell-exact transcriptions, provenance-documented in `docs/DATA_PROVENANCE.md`. Not formula approximations. |
| Conformance vectors | generated from `PlateworksCore` via `swift run plateworks-vectors` → `conformance/vectors.json` |

**Rule:** change `PlateworksCore` first, then port to `web/engine.js`. The web side never leads.

## Parity discipline (the core rule)

The two implementations must never drift. Parity is **enforced by the build, not by diligence**:

- `node conformance/check-web.js` replays the Swift-generated golden vectors against `web/engine.js` — tables, ignition chains, psychrometrics, radio scripts, and **byte-exact** IMET `.xlsx`. CI fails on any disagreement.
- When an iOS-side change lands on `main` without its web counterpart, a **GitHub Actions agent (`.github/workflows/web-parity-agent.yml`) ports it and opens a draft parity PR** gated by the same checks.
- Full design & contributor rules: `docs/PARITY.md`.

If you touch calculation on either side, regenerate vectors and run the conformance check before claiming done.

## Build & test

```sh
swift test                    # PlateworksCore suite — runs on any Swift toolchain (incl. Linux CI)
node conformance/check-web.js # web ⇄ core parity gate
```

The SwiftUI app is gated too, by the `app-build` CI job (macOS runner): XcodeGen
generate → build for iOS Simulator **and** macOS → `PlateworksIgnitionTests` →
`PlateworksIgnitionUITests`. Both app test bundles are real gates now; if you touch
`App/`, expect them to run. UI tests launch with `-uiTestingResetState` so each
starts from first-launch defaults — see `AppEnvironment`.

Native app (macOS + Xcode):
```sh
brew install xcodegen         # once
xcodegen generate             # PlateworksIgnition.xcodeproj from project.yml
```

**Device builds (physical iPhone):** the signing team lives in
`signing.local.xcconfig` (git-ignored; see `signing.xcconfig` for the shape),
pulled in at project level so it survives `xcodegen generate`. **Never pass
`DEVELOPMENT_TEAM=` on the `xcodebuild` command line** — a command-line team
override breaks `-allowProvisioningUpdates`' App Group registration: the
generated profiles come back with an *empty* `application-groups` array and all
four signed targets fail with "doesn't match the entitlements file's value".
With the team in the xcconfig, `xcodebuild build -scheme PlateworksIgnition
-destination 'generic/platform=iOS' -allowProvisioningUpdates` provisions
everything (cert, App IDs, App Groups, profiles) unattended.
The color palette is generated: `python3 scripts/generate_color_assets.py`.

The `web/` app has **no build step** and no dependencies — it's static files served as-is.

## Deploy & hosting

- **Continuous deploy:** the web app is a **git-connected Netlify site** (`plateworks-ignition`). Pushing to `main` auto-deploys `web/` (base directory `web/`, no build command). There is no manual deploy step.
- **When you change any cached web asset, bump `CACHE` in `web/sw.js`** — bump the trailing integer, never reword the prefix. Read the current value from the file; do not assume one. If you skip the bump, field devices keep serving the old app offline.
- **Domain:** `ignition.plateworks.org` (canonical). `obs.plateworks.org` is a domain alias that **301-redirects** (rule in `web/netlify.toml`). Proxied CNAMEs → `plateworks-ignition.netlify.app` in the `plateworks.org` Cloudflare zone.
- **Legacy hosts** `ignition.badwater.guide` / `obs.badwater.guide` 301 to the canonical host via a Cloudflare redirect rule in the `badwater.guide` zone (cutover 2026-07-28, migration Phase 2; the 48h tombstone dwell was waived — the app was pre-launch with no installed users). Their DNS points at a proxied dummy (`A 192.0.2.1`); the old `badwater-ignition` Netlify site is deleted. The `tombstone` branch remains in the repo as the record of the cutover; it serves nothing and must never be merged.
- GitHub: `domalhambra/plateworks-ignition` (renamed from `badwater-ignition`; old URLs redirect, but anything comparing `github.repository` by string — workflow repo guards — must use the new name).

## Guardrails

- **"Obs" is a feature, not the brand.** The app's two tabs are **Ignition · Obs** (Obs = the weather-observations tab; the wet-bulb humidity calculation lives inside Ignition's weather group, not on a tab of its own). The product is **"Plateworks Ignition"** (singular, matching the native app, whose `CFBundleDisplayName` has said so since the Phase 2 rename). The web PWA caught up on 2026-07-28 — its manifest `name`, `<title>`, status bar, icon `aria-label`, and export filename had all still said "Badwater Ignition", which is what an installed copy showed on the home screen. `short_name` stays **"Ignition"**, matching the watch and extension targets. Never rename the "Obs" tab/feature vocabulary to "Ignition," and never re-plural the brand.
- **Two "Badwater" strings in `web/` are load-bearing and must not be rebranded.** `LS_KEY = "badwater.obs.v1"` in `app.js` is the localStorage key holding every saved observation — renaming it orphans a firefighter's logged data on next open. `CACHE` in `sw.js` is a version string, not branding; bump it, never reword it. Both look like leftover brand copy and are not.
- **Safety-relevant, decision-support only.** Not affiliated with or endorsed by the NWCG. Keep the disclaimer intact; keep every table value provenance-documented.
- **Where a computed value may appear** (settled by design review; full reasoning in `docs/PLAN_WIDGET_AND_WATCH.md`):
  - **Persistent, glanceable surfaces — widgets, complications, Live Activities, lock-screen notifications — show only *frozen, logged* observations**, always with time and age, and stop showing the number once it's superseded. The live estimate never reaches them.
  - **Transient, explicitly-requested read-outs may report the live estimate** — the operator asked a second ago and hears the IRPG caveat in the same breath. This is why `CurrentIgnitionIntent` speaking a live PIG is fine and a widget showing one is not.
  - **Freezing a reading requires the capture card.** No surface outside the app creates an observation — hence the log intent opens the app, and the watch app is read-only.
  - The line is *not* "computed values never leave the app": the radio script, IMET `.xlsx` and NWS spot request have always carried PIG outward and are right to. The line is **volatile vs. frozen** and **persistent vs. transient**.
- **Offline-first & private.** All compute runs on-device / in-page, and **no observation data ever leaves the device**. That is the invariant; keep it absolute. The native app collects nothing at all (see `PrivacyInfo.xcprivacy`). The **web PWA** carries one outbound host as of 2026-07-28: Plausible analytics — cookieless, no personal data, no cross-site tracking — allowed explicitly in `web/netlify.toml`'s CSP under both `script-src` and `connect-src`. It is deliberate, not drift; **do not "fix" the CSP by removing it.** Since 2026-08-17 it carries named interaction events too (`web/analytics.js`), under a rule that keeps the invariant absolute: **events name which control was used, never what was entered** — no reading, note, coordinate or count of observations is ever a prop, and the smoke test asserts it. Full taxonomy and constraints in `docs/ANALYTICS.md`. Beyond that one host, don't add network dependencies, and never route anything a user typed through one.
- Follows the workspace **Project Conventions** in `../CLAUDE.md` (plan before multi-step work; verification is the last step; reciprocal cross-referencing). For session logs, use § Session logging below.

## Map of the repo

| Path | What |
|---|---|
| `Sources/PlateworksCore/` | pure calculation core (source of truth) |
| `Sources/PlateworksVectors/` | `swift run plateworks-vectors` — emits conformance vectors |
| `App/PlateworksIgnition/` | SwiftUI app (iOS/macOS) + its test targets |
| `web/` | offline PWA (engine.js, app.js, analytics.js, index.html, sw.js, manifest, netlify.toml) |
| `conformance/` | golden vectors + Node parity harness |
| `PROJECT_CHARTER.md` | vision, status, milestones |
| `DESIGN.md` | design system |
| `docs/PARITY.md`, `docs/DATA_PROVENANCE.md`, `docs/APP_STORE.md` | parity machinery, table provenance, store listing draft |
| `docs/ANALYTICS.md` | what the web PWA reports to Plausible, and the rule that keeps readings out of it |
| `docs/UX_TWO_TAB.md`, `docs/PLAN_TWO_TAB.md` | the two-tab restructure — design record and its implementation plan |
| `docs/RED_TEAM.md` | red-team findings, what's fixed vs. recommended, iOS capability roadmap |
| `docs/IMPLEMENTATION_PLAN.md` | sequenced plan for the red-team recommendations + iOS capabilities (dependencies, verification, cloud-vs-Mac split) |
| `ATTRIBUTION.md` | NWCG public-domain sourcing + disclaimer |

## Session logging

Log sessions to the Notion **Session Log** database. This is written here, in the repo, on purpose: a cloud container clones only this repo, so a convention that lives in the workspace CLAUDE.md or a Mac-local skill never reaches it. Everything needed is below — no other file required.

- Parent: `{"type": "data_source_id", "data_source_id": "60f3ea17-4424-4815-8a4b-6a4d4de61c4f"}`
- `Session Title` (title) and `date:Date:start` (ISO date — note the expanded property name, not `Date`)
- `Repo` — relation. **This repo is** `["https://app.notion.com/p/3a44f171f4728170b004e017a4ada0ba"]`
- `Activity` — build | fix | research | write | ops | plan
- `Status` — Complete | In Progress | Blocked
- `Shipped` — checkbox (`"__YES__"`) for deploys and launches
- `Tags` — JSON array **encoded as a string**, not a native array. It is a
  constrained multi-select. A value outside the allowed set fails the whole write
  with a `validation_error`. Allowed today: `skill development`, `Notion`,
  `admin`, `Human Design`, `coaching`, `writing`, `DMIHC`, `Claude`,
  `Ghost CMS`, `SEO`, `Tecopa Plateworks`. Pick from these; do not invent one. If
  none fit, omit `Tags`. A missing tag costs nothing; an invented one loses the
  whole log.
- `Quarter` computes itself from Date. Never set it by hand.

Body sections: What We Did / Open Threads / Next Steps / Notes.

Also open a **Threads** record for work deliberately left unfinished, and a **Decisions** record for any durable choice that will constrain future work.

**If Notion is unreachable** — no connector attached in this container, or offline — append the entry to this repo's own `SESSION_LOG.md` (newest first, append-only, never rewrite history) and say so plainly in the closing summary. Confirm the Notion write returned a page ID before reporting the log as done. A log that silently doesn't happen is the failure this fallback exists to prevent.
