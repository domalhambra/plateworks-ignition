import SwiftUI
import PlateworksCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The **Watch** screen (Weather Watch — the shift observation log).
///
/// This screen is the **record**: the latest-reading hero and its frozen radio
/// broadcast, a shift trend, the shift log (with delete + undo), the site &
/// radio block (``SiteEditor``, which owns the IMET header, the GPS position
/// autofill, and the shared site factors), and the shift exports (IMET `.xlsx`,
/// NWS spot, Notes).
///
/// Entering a reading is *not* here — it happens in ``ObsFormSheet``, opened by
/// the bottom bar. The capture controls used to sit ninth in this scroll, below
/// everything above, which put the app's most repeated action behind the whole
/// record; now the scroll is only what has already been frozen. The first log of
/// a shift is still gated on an explicit site review, so a persisted default can
/// never silently feed a broadcast — an unconfirmed site can't open the form.
@MainActor
struct WatchView: View {
    @Bindable var model: WeatherWatchModel
    @Bindable var ignition: IgnitionModel
    /// Raised by the log-observation App Intent. That intent means "start a
    /// log", so arriving from it opens the capture form instead of dropping the
    /// operator at the top of the record with the form one tap away — but it
    /// still respects the site gate, which is the one thing that may stand
    /// between a launch and a broadcast.
    var startCapture: Binding<Bool> = .constant(false)
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    /// The workbook bytes for a presented export sheet, built once when the
    /// export is requested rather than on every body pass.
    @State private var workbookDocument: IMETWorkbookDocument?
    /// Whether an undo affordance for the last delete is showing.
    @State private var showUndo = false
    /// The observation form, when one is up: capturing the next reading or
    /// correcting a logged one (nil = closed). Both go through ``ObsFormSheet``,
    /// so the two paths can't drift into different layouts.
    @State private var formPresentation: ObsFormSheet.Presentation?
    /// Drives the IMET `.xlsx` export sheet.
    @State private var exportingWorkbook = false
    /// Guards the new-shift action (which archives the current shift) behind a confirm.
    @State private var confirmNewShift = false
    /// Guards the destructive clear-all-history action behind a confirm.
    @State private var confirmClearHistory = false
    /// The archived day pending deletion (nil = no confirm showing).
    @State private var shiftToDelete: Shift?
    /// Wall-clock reference for the "next obs due" countdown and the pending obs
    /// time. Advanced by a `.task` loop (see ``body``) rather than a
    /// `Timer.publish` — an autoconnected publisher keeps a run-loop source alive
    /// for as long as the view exists, including while the Obs tab is off screen,
    /// and every tick re-evaluated this whole body. Battery is a safety input on
    /// a 16-hour shift.
    @State private var now = Date()

    /// Standard hourly weather-watch cadence for the next observation.
    private let obsCadence: TimeInterval = 60 * 60
    /// Which metric the shift trend plots.
    @State private var trendMetric: ObservationMetric = .probabilityOfIgnitionUnshaded
    /// Haptic triggers. A gloved tap on a phone held at arm's length gives no
    /// tactile confirmation of its own, and the operator is usually looking at
    /// the weather rather than the screen — so a log and a delete each announce
    /// themselves. `.success` for a log, `.warning` for a deletion, matching what
    /// those feedbacks mean everywhere else on the platform.
    @State private var logHaptic = 0
    @State private var deleteHaptic = 0
    /// Schedules the "next obs due" reminder so the cadence survives the app
    /// being backgrounded — the on-screen countdown only works while it isn't.
    #if canImport(UserNotifications)
    @State private var cadence = ObsCadenceScheduler(center: SystemNotificationCenter())
    #endif

    /// Owns the lock-screen / Dynamic Island countdown. Created once with the
    /// view, and adopts any activity already running from a previous launch —
    /// without that, a relaunch orphans the old countdown and starts a second
    /// one, and the crew sees two that disagree.
    #if os(iOS)
    @State private var obsActivity = ObsActivityController()
    #endif

    /// Mirrors the shift's latest observation to a paired watch. Read-only on
    /// the far side — freezing a reading requires the capture card here.
    #if canImport(WatchConnectivity)
    @State private var watchSession = WatchSessionSender()
    #endif

    private var hasObs: Bool { !model.shift.obs.isEmpty }
    /// The trend overlays every retained day, so it's available once ≥2 obs exist
    /// across the history and the current shift (not just the current one).
    private var canTrend: Bool { model.allShifts.reduce(0) { $0 + $1.obs.count } >= 2 }
    /// There's something to export/manage when the current shift has obs or any day
    /// is retained in history (so the export + record controls survive a fresh shift).
    private var hasExportableData: Bool { hasObs || !model.history.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.sectionSpacing) {
                header
                if model.persistenceFailed { persistenceWarning }
                obsDueStrip
                if let latest = model.latest {
                    hero(latest)
                    broadcastSection(latest)
                } else {
                    emptyState
                }
                if canTrend { trendSection }
                if hasObs { shiftLogSection }
                SiteEditor(model: model, ignition: ignition)
                if hasExportableData { exportSection }
                if !model.history.isEmpty { historySection }
                if hasObs { newShiftRow }
                disclaimer
            }
            .padding(Metric.screenPadding)
        }
        .safeAreaInset(edge: .bottom) { logBar }
        .sheet(item: $formPresentation) { presentation in
            ObsFormSheet(
                presentation: presentation, model: model, ignition: ignition,
                onLogged: { _ in
                    logHaptic += 1
                    // Permission is asked here, at the point of value — the first
                    // log — rather than on a cold launch before the operator
                    // knows what the app does.
                    #if canImport(UserNotifications)
                    Task {
                        await cadence.requestAuthorizationIfNeeded()
                        cadence.reschedule(latestObs: model.latest?.timestamp)
                    }
                    #endif
                    // Outside the #if: the widget follows the record, not the
                    // notification permission, and this is the mutation it
                    // exists for.
                    reloadGlanceSurfaces()
                },
                onSaved: { rescheduleCadence() })
        }
        .background(PlateworksColor.background)
        // Hidden for the same reason as IgnitionView's: no push navigation,
        // and the tab bar + in-content header already name the screen twice.
        .navigationBarHiddenOnIOS()
        // Suspends with the view: leaving the tab cancels the loop, and a
        // suspended app doesn't run it at all.
        .task {
            while !Task.isCancelled {
                tick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { tick() } }
        .onAppear { tick(); consumeStartCapture() }
        .onChange(of: startCapture.wrappedValue) { _, _ in consumeStartCapture() }
        .sensoryFeedback(.success, trigger: logHaptic)
        .sensoryFeedback(.warning, trigger: deleteHaptic)
    }

    /// Open the capture form once, if an intent asked for it. Consumed either
    /// way — a gated shift leaves the operator on the record, where the Confirm
    /// site action is, rather than re-opening the form on every appear.
    private func consumeStartCapture() {
        guard startCapture.wrappedValue else { return }
        startCapture.wrappedValue = false
        guard !model.needsSiteConfirmation else { return }
        formPresentation = .capture
    }

    /// Re-point the due reminder at the shift's current latest observation, and
    /// refresh the surfaces that mirror the record. A delete, an undo, or a
    /// corrected timestamp can all move the next-obs moment, and a stale
    /// reminder would fire for a reading that no longer exists.
    private func rescheduleCadence() {
        #if canImport(UserNotifications)
        cadence.reschedule(latestObs: model.latest?.timestamp)
        #endif
        reloadGlanceSurfaces()
    }

    /// Tell every glanceable surface the record moved — the widget, and the
    /// Live Activity counting down to the next observation.
    ///
    /// The widget's timeline policy is `.never` — two entries and done — so it
    /// refreshes only when asked. That is what makes it free to run for a
    /// 16-hour shift, and it is also why every mutation has to call this: miss
    /// one and the home screen keeps showing a superseded reading with no clock
    /// to correct it.
    ///
    /// Called from all five: log, edit, delete, undo, new shift. Note that the
    /// log and new-shift paths do **not** route through ``rescheduleCadence()``
    /// — they talk to the scheduler directly, one to ask permission first and
    /// one to cancel rather than re-point — so they call this themselves.
    private func reloadGlanceSurfaces() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        #if os(iOS)
        // One call for all five events: the controller works out start vs
        // update vs end from what the shift's latest observation now is. An
        // empty shift — last obs deleted, or a new shift — ends the countdown.
        obsActivity.sync(latest: model.latest, siteLabel: liveActivitySiteLabel)
        #endif
        #if canImport(WatchConnectivity)
        // Replaces rather than queues, so the watch mirrors the latest reading
        // and never receives a backlog of a shift's intermediate observations.
        watchSession.send(latest: model.latest, siteLabel: liveActivitySiteLabel)
        #endif
    }

    /// The division or location the countdown is captioned with. Fixed for the
    /// activity's life, so it is only read when one starts.
    private var liveActivitySiteLabel: String? {
        for candidate in [model.shift.division, model.shift.locationName] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Advance the wall-clock reference the due countdown reads from. The obs
    /// timestamp is no longer this view's concern — it is seeded and tracked
    /// inside ``ObsFormSheet``, which only exists while a reading is being
    /// entered.
    private func tick() {
        now = Date()
    }

    // MARK: - Next-obs-due annunciator

    /// Always-present cadence strip: how long until the next hourly observation is
    /// due (from the last logged obs), turning to caution amber within 5 minutes
    /// of — and after — the due time, so a weather watch stays a *prospective*
    /// discipline rather than a log noticed an hour late. No obs yet ⇒ take one now.
    private var obsDueStrip: some View {
        let icon: String, message: String, caution: Bool
        if let last = model.latest?.timestamp {
            let due = last.addingTimeInterval(obsCadence)
            let mins = Int(due.timeIntervalSince(now) / 60)   // truncates toward zero
            if mins <= 5 {
                caution = true
                icon = "clock.badge.exclamationmark"
                message = mins >= 0
                    ? "Obs due now · \(clock(due))"
                    : "Obs overdue \(-mins) min · was due \(clock(due))"
            } else {
                caution = false
                icon = "clock"
                message = "Next obs \(clock(due)) · in \(mins) min"
            }
        } else {
            caution = false
            icon = "clock"
            message = "First obs of the shift — take one now"
        }
        return StatusStrip(icon: icon, message: message, caution: caution, identifier: "obs-due")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Obs").font(PlateworksFont.title).foregroundStyle(PlateworksColor.ink)
            Spacer()
            Text(shiftSummary).fieldLabel()
        }
    }

    private var shiftSummary: String {
        let n = model.shift.obs.count
        return n == 0 ? "IRPG PMS 461" : "\(n) obs this shift"
    }

    // MARK: - Latest-reading hero

    private func hero(_ obs: WeatherObs) -> some View {
        let e = obs.estimate
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(obs.timeLabel())
                    .readout(24)
                    .foregroundStyle(PlateworksColor.ink)
                Text("Latest").fieldLabel()
                Spacer()
            }
            HStack(spacing: 10) {
                ResultCard(title: "Unshaded", pig: e.unshaded.probabilityOfIgnition,
                           severity: e.unshaded.interpretation.color,
                           subtitle: "FFM \(e.unshaded.fineFuelMoisture)% · <50% shade")
                ResultCard(title: "Shaded", pig: e.shaded.probabilityOfIgnition,
                           severity: e.shaded.interpretation.color,
                           subtitle: "FFM \(e.shaded.fineFuelMoisture)% · ≥50% shade")
            }
            radioLine(obs)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlateworksColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Metric.resultRadius))
        .overlay(RoundedRectangle(cornerRadius: Metric.resultRadius).strokeBorder(PlateworksColor.hairline))
    }

    /// The radio-ready broadcast line, e.g. "Wx obs 1430, temp 90, RH 8, …".
    private func radioLine(_ obs: WeatherObs) -> some View {
        Text(obs.radioLine(timeLabel: obs.timeLabel()))
            .font(PlateworksFont.labelSmall)
            .foregroundStyle(PlateworksColor.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(PlateworksColor.surfaceSunk, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PlateworksColor.hairline))
            .accessibilityIdentifier("radio-line")
    }

    // MARK: - Broadcast panel (M4)

    /// The full spoken broadcast for the latest obs — the frozen script that went
    /// out over the air — with a Share action for the radio operator.
    private func broadcastSection(_ obs: WeatherObs) -> some View {
        let script = model.broadcastScript(for: obs)
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Broadcast", annotation: "Radio")
            Text(script)
                .font(PlateworksFont.body)
                .foregroundStyle(PlateworksColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .padding(.top, 10)   // leave room for the inset Copy pill
                .background(PlateworksColor.surfaceSunk, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PlateworksColor.hairline))
                .overlay(alignment: .topTrailing) {
                    Button { copyToPasteboard(script) } label: {
                        Text("Copy")
                            .font(PlateworksFont.labelSmall).fontWeight(.bold)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(PlateworksColor.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(PlateworksColor.accent, lineWidth: 1))
                            .foregroundStyle(PlateworksColor.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(7)
                    .accessibilityIdentifier("copy-broadcast")
                }
                .accessibilityIdentifier("broadcast-script")
        }
    }

    // MARK: - Trend (M5)

    /// One line per retained local day, points projected onto a shared clock, most
    /// recent day flagged so the chart can draw it solid.
    private func dayLines(_ metric: ObservationMetric) -> [DayLine] {
        let series = model.daySeries(of: metric)
        let latest = series.last?.day
        return series.map { entry in
            DayLine(id: entry.day,
                    label: Self.trendDayFormatter.string(from: entry.day),
                    isLatest: entry.day == latest,
                    points: entry.points.map {
                        TrendPoint(id: $0.date, clock: Self.clockProjection($0.date), value: $0.value)
                    })
        }
    }

    private var trendSection: some View {
        let lines = dayLines(trendMetric)
        let allVals = lines.flatMap { $0.points.map(\.value) }
        // Percent metrics pin to 0–100; °F metrics (temp / dew point) auto-fit.
        let domain: ClosedRange<Int> = trendMetric.unit == "%"
            ? 0...100
            : ((allVals.min() ?? 0) - 5)...((allVals.max() ?? 100) + 5)
        let annotation = lines.count > 1 ? "\(trendMetric.shortLabel) · \(lines.count) days" : trendMetric.shortLabel
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Trend", annotation: annotation)
            ChipPicker(title: "Metric", options: ObservationMetric.allCases,
                       selection: $trendMetric, label: \.shortLabel)
            if allVals.count >= 2 {
                ShiftTrendChart(days: lines, domain: domain, unit: trendMetric.unit)
                    .padding(12)
                    .background(PlateworksColor.surfaceSunk, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PlateworksColor.hairline))
            } else {
                Text("Not enough observations record \(trendMetric.shortLabel.lowercased()) yet.")
                    .font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        }
    }

    /// Project a timestamp onto a fixed reference day, keeping only its wall-clock
    /// hour+minute, so every day's line shares one time-of-day x-axis.
    private static func clockProjection(_ date: Date) -> Date {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: date)
        return cal.date(from: DateComponents(year: 2001, month: 1, day: 1,
                                             hour: c.hour ?? 0, minute: c.minute ?? 0)) ?? date
    }

    private static let trendDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    // MARK: - Shift log + delete/undo (M3)

    private var shiftLogSection: some View {
        let ordered = model.shift.obs.sorted { $0.timestamp > $1.timestamp }
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Shift log", annotation: "\(model.shift.obs.count) obs")
            if showUndo, model.undoableRemovalCount > 0 {
                // The count is shown so a second delete can't hide the first: the
                // strip used to read "Observation removed" while silently holding
                // only the most recent one.
                StatusStrip(
                    icon: "arrow.uturn.backward",
                    message: model.undoableRemovalCount == 1
                        ? "Observation removed"
                        : "\(model.undoableRemovalCount) observations removed",
                    caution: true, actionTitle: "Undo",
                    action: {
                        model.undoRemoveObs()
                        if model.undoableRemovalCount == 0 { showUndo = false }
                        rescheduleCadence()
                    },
                    identifier: "undo-strip", actionIdentifier: "undo-remove")
            }
            ForEach(ordered) { obs in logRow(obs) }
        }
    }

    private func logRow(_ obs: WeatherObs) -> some View {
        let e = obs.estimate
        return HStack(spacing: 12) {
            Text(obs.timeLabel())
                .readout(17)
                .foregroundStyle(PlateworksColor.ink)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("PIG \(e.unshaded.probabilityOfIgnition)/\(e.shaded.probabilityOfIgnition)")
                        .font(PlateworksFont.label).foregroundStyle(PlateworksColor.ink)
                    if let wind = obs.wind {
                        Text(wind.spotString).font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
                    }
                }
                if let note = obs.note, !note.isEmpty {
                    Text(note).font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button { formPresentation = .edit(obs) } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PlateworksColor.accent)
                    .frame(width: Metric.tapTarget, height: Metric.tapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("edit-obs")
            .accessibilityLabel("Edit \(obs.timeLabel()) observation")
            Button(role: .destructive) {
                model.removeObs(id: obs.id)
                deleteHaptic += 1
                showUndo = true
                rescheduleCadence()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PlateworksColor.caution)
                    .frame(width: Metric.tapTarget, height: Metric.tapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("delete-obs")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlateworksColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PlateworksColor.hairline))
    }

    // MARK: - Exports (M4)

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Export", annotation: exportAnnotation)
            HStack(spacing: 10) {
                // Build the workbook once, on the tap. The document argument is
                // re-evaluated on every body pass, so constructing it inline
                // re-zipped the whole multi-day .xlsx on each 30-second tick for
                // as long as the sheet was open.
                Button {
                    workbookDocument = IMETWorkbookDocument(data: model.imetWorkbookData())
                    exportingWorkbook = true
                } label: { actionLabel("IMET .xlsx", "tablecells") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("export-imet")
                ShareLink(item: model.notesText()) { actionLabel("Notes table", "note.text") }
                    .accessibilityIdentifier("export-notes")
            }
        }
        .fileExporter(
            isPresented: $exportingWorkbook,
            document: workbookDocument,
            contentType: IMETWorkbookDocument.xlsx,
            defaultFilename: "PlateworksIgnition-observations"
        ) { _ in workbookDocument = nil }
    }

    /// The record couldn't be written to disk. The in-memory log is intact and
    /// still exportable, so the actionable instruction is "export now" rather
    /// than a bare error.
    private var persistenceWarning: some View {
        StatusStrip(
            icon: "externaldrive.badge.exclamationmark",
            message: "Couldn't save the log to this device — export the spreadsheet before you quit the app.",
            caution: true, identifier: "persistence-warning")
    }

    /// Export header annotation — surfaces the multi-day span once more than one
    /// day of observations is retained.
    private var exportAnnotation: String {
        let days = model.retainedObsDayCount()
        return days > 1 ? "\(days) days" : "Spreadsheet + notes"
    }

    // MARK: - History (retained days) + clearing

    /// The retained-days record: a reminder to export-then-clear once the log spans
    /// several days, the list of archived days (each individually removable), and a
    /// clear-all action. Present whenever any day is retained.
    private var historySection: some View {
        let obsDays = model.retainedObsDayCount()
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "History", annotation: "\(model.history.count) day\(model.history.count == 1 ? "" : "s")")
            if obsDays > 3 {
                StatusStrip(
                    icon: "tray.full",
                    message: "\(obsDays) days of observations retained — export the spreadsheet, then clear the days you don't need.",
                    caution: true, identifier: "history-reminder")
            }
            ForEach(model.history) { archived in archivedRow(archived) }
            Button(role: .destructive) { confirmClearHistory = true } label: {
                actionLabel("Clear all history", "trash")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("clear-history")
            .confirmationDialog(
                "Clear all \(model.history.count) retained day\(model.history.count == 1 ? "" : "s")? Export the spreadsheet first if you still need them.",
                isPresented: $confirmClearHistory, titleVisibility: .visible) {
                Button("Clear all history", role: .destructive) { model.clearHistory() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .confirmationDialog(
            "Delete this day's observations? Export the spreadsheet first if you still need them.",
            isPresented: Binding(get: { shiftToDelete != nil }, set: { if !$0 { shiftToDelete = nil } }),
            titleVisibility: .visible, presenting: shiftToDelete) { day in
            Button("Delete day", role: .destructive) { model.removeArchivedShift(id: day.id) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func archivedRow(_ shift: Shift) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dayLabel(shift))
                    .readout(16).foregroundStyle(PlateworksColor.ink)
                Text(archivedSubtitle(shift))
                    .font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) { shiftToDelete = shift } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PlateworksColor.caution)
                    .frame(width: Metric.tapTarget, height: Metric.tapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("delete-day")
            .accessibilityLabel("Delete \(dayLabel(shift))")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlateworksColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PlateworksColor.hairline))
    }

    /// A retained day's date, e.g. "Mon, Jul 6" — taken from its earliest obs so a
    /// night shift crossing midnight still labels by the day it began.
    private func dayLabel(_ shift: Shift) -> String {
        let date = shift.obs.map(\.timestamp).min() ?? shift.started
        return Self.dayFormatter.string(from: date)
    }

    private func archivedSubtitle(_ shift: Shift) -> String {
        var parts = ["\(shift.obs.count) obs"]
        if let d = shift.division, !d.isEmpty { parts.append(d) }
        else if let l = shift.locationName, !l.isEmpty { parts.append(l) }
        return parts.joined(separator: " · ")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f
    }()

    // MARK: - New shift (M3)

    private var newShiftRow: some View {
        Button { confirmNewShift = true } label: { actionLabel("Start new shift", "plus.circle") }
            .buttonStyle(.plain)
            .accessibilityIdentifier("new-shift")
            .confirmationDialog("Start a new shift? This shift is saved to History; the new shift starts empty.",
                                isPresented: $confirmNewShift, titleVisibility: .visible) {
                Button("Start new shift") {
                    model.startNewShift()
                    // The obs time and the pending note used to be reset here.
                    // They now live in ``ObsFormSheet``, which is created fresh
                    // each time it opens — a new shift can't inherit either.
                    showUndo = false
                    // The shift is over; its pending reminder is meaningless.
                    #if canImport(UserNotifications)
                    cadence.cancel()
                    #endif
                    // And so is the reading on the home screen — the new shift
                    // is empty, so the widget must fall back to "No obs logged"
                    // rather than keep showing the old shift's last obs.
                    reloadGlanceSurfaces()
                }
                Button("Cancel", role: .cancel) { }
            }
    }

    /// A bordered secondary action label (teal outline) shared by the export,
    /// broadcast, and new-shift buttons.
    private func actionLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title).font(PlateworksFont.body.weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: Metric.tapTarget)
        .background(PlateworksColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PlateworksColor.accent, lineWidth: 1.5))
        .foregroundStyle(PlateworksColor.accent)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 5) {
            Text("No observations yet")
                .font(PlateworksFont.title).foregroundStyle(PlateworksColor.ink)
            Text("Confirm the site, then Start an Observation").fieldLabel()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26).padding(.horizontal, 14)
        .background(PlateworksColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Metric.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metric.cardRadius)
                .strokeBorder(PlateworksColor.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        .accessibilityIdentifier("watch-empty")
    }

    private var disclaimer: some View {
        Text("PIG is app-computed — not observed, not a forecast. Verify against your IRPG.")
            .font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    // MARK: - Log bar

    /// Fixed bottom action: opens the capture sheet, where the reading is built
    /// and frozen. Disabled until the site has been confirmed for the shift, so
    /// the first-log gate still holds — an unconfirmed site can't even open the
    /// form, let alone commit through it.
    ///
    /// The bar used to carry the whole capture card's commit; the reading itself
    /// lived nine sections up the scroll. Now the button that starts the hourly
    /// loop is the same one that ends it.
    private var logBar: some View {
        StartObservationBar(gated: model.needsSiteConfirmation, identifier: "open-capture") {
            formPresentation = .capture
        }
    }

    /// Local `"HH:MM"` for the due-strip labels.
    private func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}


/// Copy text to the system pasteboard — the inset "Copy" pill on the broadcast
/// panel, and the Copy action on the post-log script. Platform-guarded so the
/// views compile for iOS and macOS.
@MainActor
func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    _ = NSPasteboard.general.setString(text, forType: .string)
    #endif
}

#Preview {
    let ignition = IgnitionModel()
    ignition.dryBulbF = 90
    ignition.relativeHumidity = 8
    let model = WeatherWatchModel(ignition: ignition)
    model.confirmSite()
    model.logObs()
    return NavigationStack { WatchView(model: model, ignition: ignition) }
}
