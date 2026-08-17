#!/usr/bin/env node
// Web UI smoke test — the two-tab restructure, driven in a real browser.
//
//   node conformance/smoke-web-ui.js
//
// This is NOT the parity gate. `check-web.js` is: it replays the Swift-generated
// vectors against `web/engine.js` and runs in CI on every push. This script
// covers the layer that harness deliberately can't see — the UI in `web/app.js`,
// where the twin can drift from the native app without a single vector moving.
// The month-freeze divergence it now guards (a manual month override on the
// Ignition tab travelling into a logged observation) was exactly that: invisible
// to the vectors, wrong in the record, wrong on the radio.
//
// Manual, not CI: it needs Playwright, which the repo does not depend on — the
// web app has no build step and no dependencies, and that is worth keeping.
// Run it when you touch `web/app.js`. It serves `web/` itself, so there is no
// separate server step.
//
// Skips cleanly (exit 0) when Playwright isn't installed, so it can be wired
// into a hook without breaking a machine that lacks it.

const http = require("http");
const fs = require("fs");
const path = require("path");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("playwright not installed — skipping web UI smoke test"); process.exit(0); }

const ROOT = path.join(__dirname, "..", "web");
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".json": "application/json",
                ".webmanifest": "application/manifest+json", ".svg": "image/svg+xml",
                ".png": "image/png", ".txt": "text/plain", ".toml": "text/plain" };

let failures = 0;
const check = (name, cond, extra) => {
  if (cond) console.log(`  ok   ${name}`);
  else { failures++; console.log(`  FAIL ${name}${extra ? " — " + extra : ""}`); }
};

const server = http.createServer((req, res) => {
  const rel = decodeURIComponent(req.url.split("?")[0]);
  const file = path.join(ROOT, rel === "/" ? "index.html" : rel);
  if (!file.startsWith(ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404); return res.end("not found");
  }
  res.writeHead(200, { "Content-Type": TYPES[path.extname(file)] || "application/octet-stream" });
  fs.createReadStream(file).pipe(res);
});

(async () => {
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}/index.html`;

  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 420, height: 900 } });
  const errors = [];
  page.on("pageerror", e => errors.push(String(e)));
  page.on("console", m => {
    if (m.type() !== "error") return;
    // A failed load of an external resource — in practice the deliberate
    // Plausible analytics script — is not an app error: the app is
    // offline-first and must work without the network, and counting it made
    // this test report FAILURE on exactly the offline condition the app
    // exists to serve. Only external-origin load failures are exempt; any
    // error from our own origin (or from page JS) still fails the run.
    const src = (m.location() || {}).url || "";
    if (/Failed to load resource/.test(m.text()) && src && !src.includes("127.0.0.1")) return;
    errors.push(m.text());
  });
  await page.addInitScript(() => localStorage.clear());
  // Record analytics events instead of sending them. Installed before any page
  // script, so index.html's `window.plausible = window.plausible || …` stub
  // keeps this spy and the real plausible.io script (which never loads here
  // anyway, and skips localhost by default) can't overwrite it.
  await page.addInitScript(() => {
    window.__pa = [];
    window.plausible = function () { window.__pa.push([].slice.call(arguments)); };
    window.plausible.init = function () {};
  });
  await page.goto(base, { waitUntil: "networkidle" });
  const settle = () => page.waitForTimeout(150);

  console.log("\n[shell]");
  const tabs = await page.$$eval(".tab", els => els.map(e => e.textContent.trim()));
  check("exactly two tabs", tabs.length === 2, JSON.stringify(tabs));
  check("tabs are Ignition and Obs",
    tabs.some(t => /Ignition/.test(t)) && tabs.some(t => /Obs/.test(t)), JSON.stringify(tabs));

  console.log("\n[ignition — the absorbed Humidity screen]");
  check("direct mode hides the sling readouts",
    !(await page.$("text=Dew point")) && !(await page.$(".aktoggle")));
  await page.click('[data-action="set"][data-field="rhSource"][data-val="wetBulb"]');
  await settle();
  check("wet-bulb shows dew point", !!(await page.$("text=Dew point")));
  check("wet-bulb shows WB depression", !!(await page.$("text=WB depression")));
  check("wet-bulb shows the Alaska toggle", !!(await page.$(".aktoggle")));
  const conus = await page.$$eval('[data-field="band"]', e => e.map(x => x.textContent.trim()));
  await page.click(".aktoggle input"); await settle();
  const ak = await page.$$eval('[data-field="band"]', e => e.map(x => x.textContent.trim()));
  check("Alaska relabels the band chips", JSON.stringify(conus) !== JSON.stringify(ak));
  check("Alaska band-1 label matches ElevationBand.alaskaLabel", ak[0] === "0–300 ft", ak[0]);
  // Read the effective RH off the pinned bar. It used to be read from the
  // group's own `.derived` readout, which was dropped as a duplicate of exactly
  // this node — the check went stale (and this whole script stopped running) at
  // that commit, since it is manual rather than CI.
  const pinnedRH = () => page.$eval(".pigbar .wxrow", el => {
    const n = [...el.querySelectorAll(".wxnode")].find(x => x.querySelector(".k").textContent.trim() === "RH");
    return n.querySelector(".v").textContent.trim();
  });
  const rhAk = await pinnedRH();
  await page.click(".aktoggle input"); await settle();
  const rhConus = await pinnedRH();
  check("Alaska changes labels, not arithmetic", rhAk === rhConus, `${rhAk} vs ${rhConus}`);
  await page.click('[data-action="set"][data-field="rhSource"][data-val="direct"]');

  console.log("\n[obs — record vs capture]");
  await page.click('[data-action="tab"][data-val="watch"]'); await settle();
  check("site factors visible where the site is confirmed", !!(await page.$('[data-field="aspect"]')));
  check("slope selector visible on Obs", !!(await page.$('[data-field="slope"]')));
  check("elevation delta visible on Obs", !!(await page.$('[data-field="elevationDelta"]')));
  check("record scroll carries no weather entry", !(await page.$('[data-field="note"]')));
  check("record scroll carries no receipt", !(await page.$("#freeze-receipt")));

  console.log("\n[capture loop]");
  check("log gated before the site is confirmed",
    await page.$eval('[data-action="openCapture"]', e => e.disabled));
  await page.click('[data-action="confirmSite"]'); await settle();
  await page.click('[data-action="openCapture"]'); await settle();
  check("capture sheet opens", !!(await page.$(".modalwrap")));
  check("receipt present at the commit", !!(await page.$("#freeze-receipt")));
  const receipt = await page.$eval("#freeze-receipt", e => e.textContent.trim());
  console.log(`       receipt: ${receipt}`);
  check("receipt names the slope", /31%\+|0–30%/.test(receipt), receipt);
  check("receipt names the obs time and its resolved band", /→/.test(receipt), receipt);

  await page.click('[data-action="closeSheet"]'); await settle();
  await page.click('[data-action="set"][data-field="aspect"][data-val="N"]'); await settle();
  await page.click('[data-action="openCapture"]'); await settle();
  const receipt2 = await page.$eval("#freeze-receipt", e => e.textContent.trim());
  check("receipt tracks a what-if site factor left on the Ignition tab",
    receipt !== receipt2, `${receipt} vs ${receipt2}`);

  await page.click('[data-action="logObs"]'); await settle();
  check("post-log broadcast screen appears", !!(await page.$(".modal .broadcast")));
  await page.click('[data-action="closeSheet"]'); await settle();
  check("sheet closes to the record", !(await page.$(".modalwrap")));
  check("logged obs becomes the hero", !!(await page.$(".hero")));
  check("shift log has the entry", !!(await page.$(".logrow")));

  console.log("\n[clock tracking — the twin of IgnitionModel.refreshClock]");
  const clk = await page.evaluate(() => {
    const d = new Date();
    const wantM = d.getMonth() + 1;
    const wantTb = timeBandFromClock(d.getHours(), d.getMinutes());
    // A restored-but-not-overridden month/band must snap back to the clock —
    // the regression here was a session restored days later still computing
    // the live PIG from the stale band while claiming "Tracking clock".
    S.clockOverridden = false; S.month = wantM === 1 ? 2 : 1; S.timeBand = wantTb === 0 ? 1 : 0;
    const moved = refreshClock();
    const rederived = { m: S.month, tb: String(S.timeBand) };
    // A manual override must still stand.
    S.clockOverridden = true; S.month = wantM === 1 ? 2 : 1;
    const heldMonth = S.month;
    const movedWhileOverridden = refreshClock();
    const held = !movedWhileOverridden && S.month === heldMonth;
    S.clockOverridden = false; refreshClock();   // restore for later checks
    return { moved, rederived, wantM, wantTb: String(wantTb), held };
  });
  check("stale non-overridden month/band re-derives from the clock",
    clk.moved && clk.rederived.m === clk.wantM && clk.rederived.tb === clk.wantTb,
    JSON.stringify(clk));
  check("a manual override still stands against the tick", clk.held);

  console.log("\n[month-freeze parity with WeatherWatchModel.pendingObs]");
  const m = await page.evaluate(() => {
    const shiftMonth = new Date(S.shiftDateMs).getMonth() + 1;
    S.month = shiftMonth === 1 ? 12 : 1;      // a what-if left on the Ignition tab
    S.clockOverridden = true;
    S.pendingMin = 13 * 60;
    logObs();
    return { frozen: S.obs[S.obs.length - 1].month, shiftMonth, override: S.month };
  });
  check("a month override never travels into the record",
    m.frozen === m.shiftMonth, `frozen=${m.frozen} shift=${m.shiftMonth} override=${m.override}`);

  console.log("\n[analytics — web/analytics.js]");
  // The privacy invariant is the point of these checks, not the coverage: the
  // event stream may name a control, never a reading. SENTINEL is typed into the
  // note field and must not appear anywhere in what would have been sent.
  const SENTINEL = "leakcanary-9137";
  const paNames = async () => page.evaluate(() => window.__pa.map(a => a[0]));
  const paFind = async (name) => page.evaluate(
    n => window.__pa.filter(a => a[0] === n).map(a => (a[1] && a[1].props) || {}), name);

  check("App Open reports the display mode",
    (await paFind("App Open")).some(p => p.mode === "Browser"), JSON.stringify(await paFind("App Open")));

  await page.evaluate(() => { window.__pa.length = 0; });
  await page.click('[data-action="tab"][data-val="ignition"]'); await settle();
  await page.click('[data-action="tab"][data-val="watch"]'); await settle();
  check("tab switches are reported by name",
    JSON.stringify((await paFind("Tab")).map(p => p.tab)) === '["Ignition","Obs"]',
    JSON.stringify(await paFind("Tab")));

  // A stepper burst must collapse to one event naming the field — per-tap events
  // would bury everything else and say nothing extra.
  await page.click('[data-action="tab"][data-val="ignition"]'); await settle();
  // Let any adjustment still coalescing from the sections above land first, so
  // this measures only the burst below.
  await page.waitForTimeout(3000);
  await page.evaluate(() => { window.__pa.length = 0; });
  for (let i = 0; i < 5; i++) { await page.click('[data-action="step"][data-field="dryBulbF"]'); }
  const dryAdjusts = async () => (await paFind("Adjust")).filter(p => p.field === "dryBulbF");
  check("a stepper burst sends nothing yet", (await dryAdjusts()).length === 0);
  await page.waitForTimeout(3000);
  check("a stepper burst collapses to one Adjust naming the field",
    (await dryAdjusts()).length === 1, JSON.stringify(await paFind("Adjust")));

  await page.evaluate(() => { window.__pa.length = 0; });
  await page.click('[data-action="tab"][data-val="watch"]'); await settle();
  await page.click('[data-action="openCapture"]'); await settle();
  await page.fill('[data-field="note"]', SENTINEL);
  await page.click('[data-action="logObs"]'); await settle();
  await page.click('[data-action="closeSheet"]'); await settle();
  await page.click('[data-action="copy"][data-kind="broadcast"]'); await settle();
  await page.click('[data-action="exportXlsx"]'); await settle();
  const names = await paNames();
  check("capture funnel is reported", names.includes("Capture Opened") && names.includes("Observation Logged"),
    JSON.stringify(names));
  check("sheet close names the sheet",
    (await paFind("Sheet Closed")).some(p => p.sheet === "Broadcast"), JSON.stringify(await paFind("Sheet Closed")));
  check("radio-script copy is reported by kind",
    (await paFind("Copy")).some(p => p.kind === "Broadcast"), JSON.stringify(await paFind("Copy")));
  // The blob: download is invisible to Plausible's own file-download detector —
  // if this regresses, the export silently stops being counted.
  check("the .xlsx export is reported", names.includes("Export Spreadsheet"), JSON.stringify(names));

  const leak = await page.evaluate(sent => {
    const blob = JSON.stringify(window.__pa);
    // The note text, and the live readings, must not appear in any event.
    const readings = [String(S.dryBulbF), String(S.relativeHumidity), String(S.wetBulbF)];
    return { sentinel: blob.includes(sent), readings: readings.filter(r => new RegExp("\\b" + r + "\\b").test(blob)), blob };
  }, SENTINEL);
  check("no typed text reaches the event stream", !leak.sentinel, leak.blob.slice(0, 200));
  check("no reading reaches the event stream", leak.readings.length === 0, leak.readings.join(","));

  console.log("\n[page health]");
  check("no page errors", errors.length === 0, errors.slice(0, 3).join(" | "));

  await browser.close();
  server.close();
  console.log(`\n${failures === 0 ? "web UI smoke OK" : failures + " FAILURE(S)"}`);
  process.exit(failures === 0 ? 0 : 1);
})();
