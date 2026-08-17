"use strict";
//====================== Plausible instrumentation (web only) ======================
// The app is one page with no routing, no <a> and no <form>, so Plausible's
// automatic capture sees a single pageview per load and nothing else — every tab
// switch, logged observation, export and radio-script copy was invisible. The
// dashboard-side extensions don't help here either: outbound links and form
// submissions have nothing to fire on, and the .xlsx export hands the browser a
// `blob:` URL, which the file-download detector can't recognise as a download.
// This file supplies the missing events.
//
// It has NO native counterpart — analytics is a property of the hosted web app,
// not of PlateworksCore or App/. Nothing here participates in parity.
//
// Two rules hold this file to the privacy invariant in CLAUDE.md:
//
//   1. It is strictly observational. It registers its own listeners and never
//      calls into the app; app.js is untouched. It reads `S` (the shared global
//      lexical scope of classic scripts) but never writes to it. A bug in here
//      cannot change a PIG.
//   2. **No observation data ever leaves the device.** Events carry feature
//      names only — which control was used, never what was entered. Nothing is
//      read out of `data-val`, out of an input's value, or out of `S`'s reading
//      fields; the props below are literals chosen here, so a future data-*
//      attribute carrying operator text cannot leak by accident. Temperature,
//      RH, wind, PIG, notes, coordinates, elevation, site and division names
//      never appear in an event, and neither do counts of them.
//
// Everything is best-effort: wrapped so a failure is silent, and a no-op when
// the script is blocked or the device is offline.

(function () {
  // The stub in index.html queues into plausible.q until the real script loads.
  // Offline — which is most of a shift — it never loads, so cap the queue rather
  // than growing an array all day for events that may never be sent.
  var MAX_QUEUED = 50;

  function send(name, props) {
    try {
      var p = window.plausible;
      if (typeof p !== "function") return;
      if (p.q && p.q.length >= MAX_QUEUED) return;
      p(name, props ? { props: props } : undefined);
    } catch (e) { /* analytics must never surface to the operator */ }
  }

  // Field/action identifiers are already safe literals from our own markup;
  // clamp them anyway so this stays true if the markup changes.
  function ident(v) { return typeof v === "string" && /^[A-Za-z][A-Za-z0-9]{0,23}$/.test(v) ? v : "other"; }

  var TAB_LABEL = { ignition: "Ignition", watch: "Obs" };
  var SHEET_LABEL = { capture: "Capture", edit: "Edit", logged: "Broadcast" };
  var COPY_LABEL = { broadcast: "Broadcast", spot: "Spot request", notes: "Notes" };
  var METRIC_LABEL = { pigU: "PIG unshaded", pigS: "PIG shaded", temp: "Temp", rh: "RH", ffmU: "FFM" };
  var RH_SOURCE_LABEL = { direct: "Direct", wetBulb: "Wet bulb" };

  //---------------------------------------------------------------- adjustments
  // Steppers, chips and text fields fire per tap and per keystroke. Sending one
  // event each would bury the meaningful events and burn the event quota, so a
  // burst of activity on one field collapses into a single "Adjust" naming that
  // field — enough to see which controls are actually used, at 1/50th the volume.
  var IDLE_MS = 2500;
  var pending = {};   // field -> timer

  function adjusted(field) {
    var f = ident(field);
    if (pending[f]) clearTimeout(pending[f]);
    pending[f] = setTimeout(function () { delete pending[f]; send("Adjust", { field: f }); }, IDLE_MS);
  }
  function flushAdjustments() {
    Object.keys(pending).forEach(function (f) {
      clearTimeout(pending[f]); delete pending[f]; send("Adjust", { field: f });
    });
  }

  //---------------------------------------------------------------- click events
  // Three destructive actions gate on window.confirm(), and one capture entry
  // point is gated on the site being confirmed — so the click alone doesn't say
  // what happened. Snapshot the few structural facts in the capture phase (which
  // runs before app.js's handler), then compare in the bubble phase (registered
  // after it, so it runs once the action has completed). Lengths and the shift
  // stamp are read to detect *whether* something happened; neither is ever sent.
  var before = null;

  function snapshot() {
    if (typeof S === "undefined") return null;
    return {
      tab: S.tab,
      sheet: S.sheet,
      obsLen: S.obs.length,
      histLen: S.history.length,
      shiftDateMs: S.shiftDateMs,
      siteConfirmed: S.siteConfirmed
    };
  }

  document.addEventListener("click", function (ev) {
    try {
      if (ev.target.closest && ev.target.closest("[data-action]")) before = snapshot();
    } catch (e) { before = null; }
  }, true);

  document.addEventListener("click", function (ev) {
    try {
      var b = ev.target.closest && ev.target.closest("[data-action]");
      if (!b) return;
      var a = b.dataset.action;
      var was = before;
      var now = snapshot();

      switch (a) {
        case "tab":
          send("Tab", { tab: TAB_LABEL[b.dataset.val] || "other" });
          break;

        // Field entry — coalesced. rhSource is the one `set` whose value is
        // reported: it names a calculation *method*, not a reading.
        case "set":
          if (b.dataset.field === "rhSource") {
            send("RH Source", { source: RH_SOURCE_LABEL[b.dataset.val] || "other" });
          } else {
            adjusted(b.dataset.field);
          }
          break;
        case "step":     adjusted(b.dataset.field); break;
        case "obsNudge":  adjusted("obsTime"); break;
        case "editNudge": adjusted("editTime"); break;

        case "resumeClock":  send("Clock Resumed"); break;
        case "toggleAlaska": send("Alaska Toggled"); break;
        case "setTrend":     send("Trend Metric", { metric: METRIC_LABEL[b.dataset.k] || "other" }); break;
        case "confirmSite":  send("Site Confirmed"); break;

        // Two doors into the capture form. From Ignition the door is barred
        // until the site is confirmed — worth seeing separately, it's the one
        // place the funnel stalls.
        case "openCapture":
          send("Capture Opened", { from: "Obs" });
          break;
        case "goCapture":
          if (now && now.sheet === "capture") send("Capture Opened", { from: "Ignition" });
          else send("Capture Gated", { from: "Ignition" });
          break;

        case "closeSheet":
          send("Sheet Closed", { sheet: (was && SHEET_LABEL[was.sheet]) || "other" });
          break;

        case "logObs":     send("Observation Logged"); break;
        case "editObs":    send("Edit Opened"); break;
        case "editSave":   send("Observation Edited"); break;
        case "editCancel": send("Edit Cancelled"); break;
        case "undo":       send("Delete Undone"); break;

        case "deleteObs":
          if (was && now && now.obsLen < was.obsLen) send("Observation Deleted");
          break;

        // Confirm-gated: only count the ones the operator went through with.
        case "newShift":
          if (was && now && now.shiftDateMs !== was.shiftDateMs) send("New Shift");
          break;
        case "clearHistory":
          if (was && now && now.histLen < was.histLen) send("History Cleared");
          break;
        case "deleteDay":
          if (was && now && now.histLen < was.histLen) send("Day Deleted");
          break;

        // The outputs that carry a reading off the app — the reason the site
        // exists. `blob:` downloads are invisible to Plausible's own detector,
        // so the export is reported here by name.
        case "exportXlsx": send("Export Spreadsheet"); break;
        case "copy":       send("Copy", { kind: COPY_LABEL[b.dataset.kind] || "other" }); break;
      }
    } catch (e) { /* never break a click */ }
    finally { before = null; }
  });

  //---------------------------------------------------------------- text entry
  document.addEventListener("input", function (ev) {
    try {
      var f = ev.target && ev.target.dataset && ev.target.dataset.field;
      if (f) adjusted(f);
    } catch (e) { /* ignore */ }
  });

  //---------------------------------------------------------------- session
  function displayMode() {
    try {
      if (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches) return "Standalone";
      if (window.navigator.standalone) return "Standalone";   // iOS Safari home-screen
    } catch (e) { /* ignore */ }
    return "Browser";
  }

  // How many operators are running the installed PWA versus a browser tab is the
  // one thing the plain pageview can't answer, and it's the number that says
  // whether the offline story is landing.
  send("App Open", { mode: displayMode() });
  window.addEventListener("appinstalled", function () { send("PWA Installed"); });

  // A shift is mostly offline, so the analytics script usually fails to load and
  // every event above sits in plausible.q unsent. When the signal comes back,
  // load it once more; it flushes the queue on init. Guarded on plausible.l (set
  // by the real script) so a script that did load is never bound twice.
  var retries = 0;
  window.addEventListener("online", function () {
    try {
      if (retries >= 3 || (window.plausible && window.plausible.l)) return;
      var existing = document.querySelector('script[src*="plausible.io"]');
      if (!existing) return;
      retries++;
      var s = document.createElement("script");
      s.async = true;
      s.src = existing.src;      // reuse the tag's own src — one place to change it
      document.head.appendChild(s);
    } catch (e) { /* ignore */ }
  });

  // Don't lose a coalesced adjustment because the app was backgrounded first.
  window.addEventListener("pagehide", flushAdjustments);
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "hidden") flushAdjustments();
  });
})();
