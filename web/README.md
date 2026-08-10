# Plateworks Ignition — web app (`ignition.plateworks.org`)

A standalone, offline-capable web build of the Plateworks Ignition field tool
(two tabs: **Ignition · Obs**, with the wet-bulb psychrometrics inside
Ignition's weather group). Everything runs in the browser — the IRPG (PMS 461)
tables, the belt‑weather‑kit psychrometrics, the radio script, and the IMET
`.xlsx` export are all computed locally, so it works with no signal on the
fireline and no observation data ever leaves the device. (The one outbound
request is cookieless Plausible page analytics — see `netlify.toml`.)

## What's in this folder

| File | Purpose |
|---|---|
| `index.html` | App shell + styles (inline CSS); loads the two scripts below. |
| `engine.js` | **Pure calculation engine** — the JS twin of `Sources/PlateworksCore` (IRPG tables, psychrometrics, radio script, IMET `.xlsx`). No DOM/storage/clock, so Node loads it for conformance testing. |
| `app.js` | UI layer — state, rendering, event wiring (the twin of `App/`). |
| `manifest.webmanifest` | PWA manifest (installable, standalone display). |
| `sw.js` | Service worker — caches the app for **offline** use. **Bump `CACHE` on every web change** or field devices keep the old app. |
| `icon.svg`, `icon-512.png`, `apple-touch-icon.png` | App icons / favicon. |
| `netlify.toml` | Publish dir + security headers + caching. |
| `robots.txt` | Allow indexing. |

This is a **static site — there is no build step** and no dependencies. The
port's fidelity to `PlateworksCore` is not taken on trust: CI replays golden
vectors generated from the Swift core against `engine.js` on every push
(`node conformance/check-web.js` — see [`docs/PARITY.md`](../docs/PARITY.md)),
down to byte-exact `.xlsx` output. Still: decision support only — verify
numbers against your own IRPG.

## Hosting (current state)

Live at **`ignition.plateworks.org`** on the git-connected Netlify site
`plateworks-ignition` — pushing to `main` auto-deploys this folder (base
directory `web/`, no build command; `netlify.toml` carries the headers).
`obs.plateworks.org` is a redirect-only alias, and the legacy
`*.badwater.guide` hosts 301 here. Authoritative hosting/DNS notes live in the
repo `CLAUDE.md` (Deploy & hosting).

To rebuild the site from scratch: Netlify → **Add new site → Import an
existing project → GitHub → `domalhambra/plateworks-ignition`**, base directory
`web`, no build command, publish directory `.` — or drag this folder onto
Netlify's Sites page for a one-off.

## Updating

Push to `main`; Netlify redeploys automatically.

When you change any cached asset, bump the cache name in `sw.js`
(`badwater-ignition-v9` → `-v10`; bump the number, never reword the prefix) so
returning devices fetch the new version.

## Notes / limitations

- This JS port is kept in sync with the Swift `PlateworksCore` by hand; the Swift
  test suite is the source of truth for the numbers.
- Data (the current shift, site/radio header) lives in the browser's local
  storage on that device — it is not synced or backed up. Export the `.xlsx`
  for a durable record.
- Decision‑support only; not affiliated with or endorsed by NWS/NWCG.
