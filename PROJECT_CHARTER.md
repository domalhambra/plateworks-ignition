# Project Charter — Plateworks Ignition

_Chartered 2026-07-18. This is a retroactive charter: the project was already mature (native app + web port + parity CI) when it was formally filed into the workspace._

## What it is

A fast, offline **iOS/macOS + web** field calculator for **Probability of Ignition (PIG)**, **Fine Fuel Moisture (FFM)**, and **relative humidity**, built cell-for-cell on the NWCG *Incident Response Pocket Guide* (IRPG, PMS 461) and belt-weather-kit tables. It walks the Table A → B/C/D correction → PIG chain that firefighters otherwise do by hand, shows its work at every step, and flags results sitting on a table cell edge (where a step can swing a whole fire-behavior band).

Decision-support only. Not affiliated with or endorsed by the NWCG.

## Vision / done state

**A public App Store release** (iOS/macOS) for the wider wildland fire community, with the web PWA as the free, install-anywhere companion. "Done" is: the native app shipped on the App Store, the web app live and at parity, and the IRPG transcription fully provenance-documented.

## Current status (2026-07-18)

- **Web PWA — LIVE** at [ignition.badwater.guide](https://ignition.badwater.guide) (Netlify, git-connected continuous deploy). Rebranded from "Badwater Obs" → "Badwater Ignition" and moved from `obs.` → `ignition.` today; old host 301-redirects.
- **Native iOS/macOS app — in development.** Source-complete with unit + UI test targets; not yet distributed (no TestFlight/App Store build yet).
- **Parity — enforced.** Conformance vectors from the Swift core replay against the web engine in CI on every push.

## Status update (2026-07-27) — renamed to Plateworks Ignition

The product was renamed **Badwater Ignition → Plateworks Ignition** while it was
still unreleased. Bundle identifiers moved `com.badwater.*` → `org.plateworks.*`
and the App Groups `group.com.badwater.ignition{,.watch}` →
`group.org.plateworks.ignition{,.watch}`; both were free to change only because
no TestFlight or App Store build had ever been uploaded and no shipped install
held data in the old group container. The Swift modules became `PlateworksCore`,
`PlateworksVectors` and `PlateworksIgnition`. Not a single IRPG table cell moved:
the conformance vectors are byte-identical outside their `meta` block.

Still carrying the old brand at the time of the rename: the hosting identifiers
below (GitHub repo, Netlify site, `badwater.guide` DNS), the `web/` PWA, and the
export disclaimer string — see the rename notes in `docs/PARITY.md`.

## Location & filing

- **Repo folder:** `Projects/Badwater OS/Badwater Ignition/`
- **GitHub:** `domalhambra/plateworks-ignition` (renamed from `badwater-ignition`, 2026-07-28)
- **Netlify site:** `plateworks-ignition` → `plateworks-ignition.netlify.app` (the old `badwater-ignition` site is deleted)
- **DNS:** Cloudflare, `plateworks.org` zone — proxied CNAMEs `ignition` (canonical) + `obs` (301 alias). Legacy `badwater.guide` hosts 301 via a redirect rule in the `badwater.guide` zone; their DNS points at a proxied dummy.
- **Workspace filing:** listed in `Badwater OS/CLAUDE.md` Projects table + Fallback route (fire-tool / IRPG questions).
- **JD context:** subject-matter home is *20-29 Work Projects* (federal wildland fire), but as a full-repo project it lives under `Badwater OS/` alongside PKM / HD / Garden.

## Architecture (see `README.md` + `DESIGN.md` for detail)

- `Sources/PlateworksCore/` — pure, dependency-free, Linux-testable calculation core (the source of truth).
- `App/PlateworksIgnition/` — SwiftUI app (iOS + macOS), generated via XcodeGen (`project.yml`).
- `web/` — static, offline-first PWA: `engine.js` (logic twin of `PlateworksCore`) + `app.js` (UI twin of `App/`).
- `Sources/PlateworksVectors/` + `conformance/` — golden vectors + Node harness that hold the two ports at parity.

## Design & reference docs

| Doc | Purpose |
|---|---|
| `DESIGN.md` | Design system (finalize in Claude Design) |
| `docs/PARITY.md` | How iOS ⇄ web parity is enforced & auto-ported |
| `docs/DATA_PROVENANCE.md` | How every IRPG table value was transcribed & verified |
| `docs/APP_STORE.md` | Draft App Store listing copy |
| `ATTRIBUTION.md` | NWCG public-domain sourcing + disclaimer |

## Logging strategy

Session work is logged to the workspace `SESSION_LOG.md` (`Badwater PKM/wiki/00-meta/`) via the session-log skill — not a repo-local log. Deploys/launches get `Status: Shipped` + `#shipped` and a shipped-index pointer.

## Verification gates

- `swift test` — `PlateworksCore` suite (golden cells, banding boundaries, property tests, worked examples) runs on Linux CI.
- **Conformance CI** — `node conformance/check-web.js` replays Swift-generated vectors against `web/engine.js`: tables, ignition chains, psychrometrics, radio scripts, and byte-exact IMET `.xlsx`. CI fails on any disagreement.
- **Web-parity agent** — when an iOS change lands on `main` without its web counterpart, a GitHub Actions agent ports it and opens a draft parity PR gated by the same checks.
- App-side: Xcode unit + UI test targets.
- Bump `sw.js` `CACHE` on every web change so field devices refetch.

## Tooling

Swift / SwiftUI · XcodeGen · vanilla-JS PWA (no build step, no deps) · Netlify (continuous deploy) · Cloudflare DNS · GitHub Actions (parity CI + agent).

## Milestones

- [x] **Web PWA live** at `ignition.badwater.guide` — 2026-07-18
- [x] Brand unified to "Badwater Ignition" across native + web — 2026-07-18
- [x] Code renamed to **Plateworks Ignition** (bundle IDs, App Groups, Swift modules) — 2026-07-27
- [x] Hosting + repo migrated: `ignition.plateworks.org` canonical, GitHub renamed to `plateworks-ignition`, legacy hosts 301 — 2026-07-28
- [ ] Finalize `DESIGN.md` design system pass
- [ ] Native app → **TestFlight beta** (first external testers)
- [ ] Finalize `docs/APP_STORE.md` listing + assets (screenshots, privacy)
- [ ] **App Store release** (iOS/macOS)
- [ ] Ongoing: keep web ⇄ iOS parity green through release

## Guardrails / principles

- **Safety-relevant.** Decision-support only; cell-exact fidelity to the printed IRPG is non-negotiable, and every table value stays provenance-documented.
- **Offline-first, private.** All compute runs on-device / in-page, and no observation data ever leaves the device. The native app collects nothing. The web PWA added cookieless Plausible analytics on 2026-07-28 — page views, and named interaction events since 2026-08-17 (no personal data, no cross-site tracking). Events name which control was used, never what was entered: no reading, note or coordinate is ever reported, and `conformance/smoke-web-ui.js` asserts it. The principle is "no user data collected", not literally "no outbound requests". See `docs/ANALYTICS.md`.
- **Parity is enforced, not promised.** The two ports never diverge silently.
