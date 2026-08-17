# Analytics — what the web app reports, and what it never will

The **web PWA only**. The native app collects nothing at all and has no
counterpart to any of this (`PrivacyInfo.xcprivacy`). Nothing here participates
in parity: `web/analytics.js` is a property of the hosted site, not a twin of
anything in `Sources/PlateworksCore` or `App/`.

Provider: **Plausible** (`plausible.io`), cookieless, no cross-site tracking, no
personal data. Site domain `ignition.plateworks.org`. Added 2026-07-28; the
interaction events below were added 2026-08-17.

## The rule

> **No observation data ever leaves the device.**

Events name *which control was used*, never *what was entered*. Temperature, RH,
wet bulb, wind, PIG, FFM, notes, coordinates, site elevation, location and
division names never appear in an event — and neither do counts of them, which
would describe the shift.

This is enforced structurally, not by care:

- Every prop value in `web/analytics.js` is a **literal chosen in that file** and
  looked up through a fixed label map. Nothing is read out of `data-val`, out of
  an input's `value`, or out of `S`'s reading fields, so a future `data-*`
  attribute carrying operator text cannot leak by accident.
- `conformance/smoke-web-ui.js` types a sentinel into the note field, drives the
  capture loop, and asserts that neither the sentinel nor any live reading
  appears anywhere in the event stream. If instrumentation ever starts carrying
  a value, that check fails.

Two `set` actions do report their value, deliberately, because each names a
*method or a view*, not a reading: `rhSource` (Direct vs. wet bulb) and the
trend metric. The tab name is reported for the same reason.

## Why custom events are needed at all

The app is one page with no routing, no `<a>` and no `<form>`. Plausible's
automatic capture therefore sees exactly one pageview per load, plus engagement.
The dashboard-side extensions don't reach it either:

| Extension | Why it never fires here |
|---|---|
| Outbound links | the app has no links |
| Form submissions | the app has no `<form>` |
| File downloads | the `.xlsx` export hands the browser a **`blob:` URL**, which has no file extension for the detector to match |

So the `.xlsx` export in particular has to be reported by name, and the smoke
test guards that specifically.

## Events

| Event | Props | Fires when |
|---|---|---|
| `pageview` | — | automatic, per load |
| `App Open` | `mode`: Standalone \| Browser | load; the one thing a pageview can't answer — installed PWA vs. browser tab |
| `PWA Installed` | — | `appinstalled` |
| `Tab` | `tab`: Ignition \| Obs | tab switch |
| `Adjust` | `field` | a burst of edits to one field settles (see coalescing) |
| `RH Source` | `source`: Direct \| Wet bulb | humidity-source chip |
| `Clock Resumed` | — | manual month/band override released |
| `Alaska Toggled` | — | Alaska band labelling |
| `Trend Metric` | `metric` | trend chart metric switched |
| `Site Confirmed` | — | site confirmed on Obs |
| `Capture Opened` | `from`: Ignition \| Obs | the capture sheet actually opened |
| `Capture Gated` | `from`: Ignition | "Start an observation" from Ignition while the site is unconfirmed — the one place the funnel stalls |
| `Observation Logged` | — | an observation is frozen |
| `Sheet Closed` | `sheet`: Capture \| Edit \| Broadcast | sheet dismissed |
| `Edit Opened`, `Observation Edited`, `Edit Cancelled` | — | correcting a logged obs |
| `Observation Deleted`, `Delete Undone` | — | delete, and the undo |
| `New Shift`, `History Cleared`, `Day Deleted` | — | **confirmed only** — the `confirm()` dialogs are counted by outcome, not by intent |
| `Export Spreadsheet` | — | IMET `.xlsx` written |
| `Copy` | `kind`: Broadcast \| Spot request \| Notes | radio script / spot request / notes copied |

### Coalescing

Steppers, chips and text fields fire per tap and per keystroke. One event each
would bury the meaningful events and burn the event quota while saying nothing
extra, so a burst of activity on one field collapses into a single `Adjust`
naming that field, sent 2.5 s after the last edit (and flushed on `pagehide` /
`visibilitychange`, so backgrounding the app doesn't drop it).

### Offline

Most of a shift has no signal, so the Plausible script usually fails to load and
events sit in its in-page `plausible.q` queue. The queue is **in memory only** —
nothing analytics-related is ever persisted — and capped at 50 events so a long
offline shift doesn't grow an array all day for events that may never be sent.
When the connection returns, `analytics.js` reloads the script once (up to three
times per session), which flushes whatever is still queued.

Because of this, offline-only sessions are under-reported by design. That is the
correct trade: nothing is written to disk to make the numbers better.

## Constraints to keep in mind when changing this

- **CSP.** `plausible.io` is allowed in `web/netlify.toml` under **both**
  `script-src` and `connect-src`. Without both, the tag looks installed and
  reports nothing. Do not "fix" the CSP by removing it.
- **Service worker.** `analytics.js` is precached in `web/sw.js`; bump `CACHE`
  when you change it. The SW ignores non-GET requests, so Plausible's event
  POSTs pass straight through.
- **`analytics.js` is strictly observational.** It registers its own listeners
  and never calls into the app; `web/app.js` is untouched by it. It reads `S`
  (classic scripts share global lexical scope) but never writes. Keep it that
  way — a bug in analytics must not be able to change a PIG.
- **404s are not counted.** A typo path is served by Netlify's default 404 page,
  which carries no tag. An SPA-style `/*` → `/index.html` fallback would fix
  that and is deliberately not used: it would mask real 404s, and the service
  worker's navigation handler exists precisely to stop a 404 body replacing the
  cached offline app.
- Verify with `node conformance/smoke-web-ui.js` (needs Playwright; manual, not
  CI).

Related: `CLAUDE.md` (guardrails), `web/README.md`, `docs/PARITY.md`.
