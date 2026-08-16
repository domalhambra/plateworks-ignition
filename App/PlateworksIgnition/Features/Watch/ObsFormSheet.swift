import SwiftUI
import PlateworksCore

/// The observation form — one sheet, two modes.
///
/// **Capture** builds the next reading and freezes it; **edit** corrects one
/// already in the record. They collect identical fields (time, weather, note),
/// so they are one view rather than the two independently-drifting layouts this
/// screen used to carry: a capture card buried in the Obs scroll and a separate
/// edit sheet that had already grown its own future-time guard while the card
/// kept a different one.
///
/// The two modes differ in exactly three ways, all deliberate:
///
/// | | Capture | Edit |
/// |---|---|---|
/// | Weather | the shared ``IgnitionModel``, written through — it *is* the live reading | isolated `@State`, so a correction never moves the live tab |
/// | Time | seeded from the clock and re-seeded until the operator takes it over | the observation's own timestamp |
/// | Commit | freeze receipt → **Log Observation** → the broadcast script | **Save** |
///
/// Capture writing through is the point, not a leak: the sheet is where the
/// operator enters what they just read off the instrument, and that reading is
/// the same one the Ignition tab shows. Dismissing without logging therefore
/// keeps the weather edits — what makes that safe to do is the receipt, which
/// names every value the freeze will take.
@MainActor
struct ObsFormSheet: View {

    /// What the sheet is doing, and to which observation.
    enum Presentation: Identifiable {
        case capture
        case edit(WeatherObs)

        var id: String {
            switch self {
            case .capture: return "capture"
            case .edit(let obs): return "edit-\(obs.id)"
            }
        }
    }

    let presentation: Presentation
    /// Plain references, not `@Bindable`: this view calls methods and reads
    /// values, and `WeatherInputGroup` makes its own binding from the object.
    /// Observation tracks the property reads either way.
    let model: WeatherWatchModel
    let ignition: IgnitionModel
    /// Fired at the moment of freeze, with the stored observation — before the
    /// success screen is dismissed, so the widget, the Live Activity and the
    /// cadence reminder are already correct while the script is being read.
    var onLogged: (WeatherObs) -> Void = { _ in }
    /// Fired after an edit is committed.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    // MARK: Shared field state

    @State private var time: Date
    @State private var note: String

    // MARK: Capture-only state

    /// The value this view last auto-seeded ``time`` to. Comparing the two is how
    /// a manual edit is detected; see ``timeIsManual``.
    @State private var autoSeeded: Date

    /// The exact future time the operator has waved through with "That's okay".
    /// Acknowledgment covers that one value — changing the time again re-arms
    /// the caution, so a further-out time is never hidden by an old dismissal.
    @State private var acknowledgedFutureTime: Date?
    /// The frozen observation once committed — its presence *is* the success
    /// screen.
    @State private var logged: WeatherObs?
    /// Wall clock for the freshness and future-time strips.
    @State private var now = Date()

    // MARK: Edit-only state (isolated from the live tab)

    @State private var dryBulb: Int
    @State private var rh: Int
    @State private var wetBulb: Int
    @State private var windLow: Int
    @State private var windHigh: Int
    @State private var gust: Int
    @State private var direction: Wind.Direction

    init(presentation: Presentation,
         model: WeatherWatchModel,
         ignition: IgnitionModel,
         onLogged: @escaping (WeatherObs) -> Void = { _ in },
         onSaved: @escaping () -> Void = {}) {
        self.presentation = presentation
        self.model = model
        self.ignition = ignition
        self.onLogged = onLogged
        self.onSaved = onSaved

        switch presentation {
        case .capture:
            let start = Date()
            _time = State(initialValue: start)
            _autoSeeded = State(initialValue: start)
            _note = State(initialValue: "")
            // Unused in capture mode — the weather comes from `ignition` — but
            // seeded from it so a stray read can't show something misleading.
            _dryBulb = State(initialValue: ignition.dryBulbF)
            _rh = State(initialValue: ignition.effectiveRelativeHumidity)
            _wetBulb = State(initialValue: ignition.wetBulbF)
            _windLow = State(initialValue: ignition.windSpeedLow)
            _windHigh = State(initialValue: ignition.windSpeedHigh)
            _gust = State(initialValue: ignition.windGustMPH)
            _direction = State(initialValue: ignition.windDirection)

        case .edit(let obs):
            let input = obs.estimate.input
            _time = State(initialValue: obs.timestamp)
            _autoSeeded = State(initialValue: obs.timestamp)
            _note = State(initialValue: obs.note ?? "")
            _dryBulb = State(initialValue: input.dryBulbF)
            _rh = State(initialValue: input.relativeHumidity)
            // Reconstruct the wet bulb from the frozen depression (slung obs
            // only; a direct obs has none, so this seeds to the dry bulb).
            _wetBulb = State(initialValue: input.dryBulbF - (obs.humidity?.wetBulbDepressionF ?? 0))
            let w = obs.wind
            _windLow = State(initialValue: w?.speed?.low ?? 0)
            _windHigh = State(initialValue: w?.speed?.high ?? 0)
            _gust = State(initialValue: w?.gust ?? 0)
            _direction = State(initialValue: w?.direction ?? .north)
        }
    }

    // MARK: - Mode helpers

    private var isCapture: Bool {
        if case .capture = presentation { return true }
        return false
    }

    private var editingObs: WeatherObs? {
        if case .edit(let obs) = presentation { return obs }
        return nil
    }

    /// True once the operator has typed or nudged the time — detected by the
    /// value having moved away from what this view last auto-seeded.
    ///
    /// Compared at **minute** granularity, not by equality: ``ObsTimeField``
    /// echoes the value back through its `"HH:MM"` text field and that round trip
    /// zeroes the seconds, so an exact comparison would read the echo as a manual
    /// edit and stop the clock tracking within one tick of the sheet appearing.
    /// Every real edit moves the value by at least a minute.
    private var timeIsManual: Bool {
        !Calendar.current.isDate(time, equalTo: autoSeeded, toGranularity: .minute)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if let logged {
                    successScreen(logged)
                } else {
                    form
                }
            }
            .background(PlateworksColor.background)
            .navigationTitle(sheetTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
        }
        // Capture keeps tracking the wall clock until the operator takes the time
        // over, so a sheet left open while the crew reads the instrument doesn't
        // stamp the moment it was opened. Suspends with the sheet.
        .task {
            guard isCapture else { return }
            while !Task.isCancelled {
                now = Date()
                if !timeIsManual && logged == nil {
                    time = now
                    autoSeeded = now
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var sheetTitle: String {
        if logged != nil { return "Logged" }
        return isCapture ? "New observation" : "Edit observation"
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if logged != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .fontWeight(.bold)
                    .accessibilityIdentifier("log-done")
            }
        } else if isCapture {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("capture-cancel")
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("edit-cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .fontWeight(.bold)
                    .accessibilityIdentifier("edit-save")
            }
        }
    }

    // MARK: - The form

    /// The form scrolls as one piece, commit included — deliberately *not* a
    /// pinned bottom bar.
    ///
    /// Two reasons. The receipt has to be read before the freeze, and a pinned
    /// button can be tapped from the top of the form without the operator ever
    /// reaching it; ending the scroll with receipt-then-button means you cannot
    /// commit without passing the thing you are meant to check. And a bottom
    /// `safeAreaInset` inside this sheet does not surface its contents to
    /// XCUITest at all, so a pinned bar would also be a bar no test can prove
    /// is there — on the one screen in the app that freezes a reading.
    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.cardSpacing) {
                if let obs = editingObs { editPreamble(obs) }
                if isCapture { pendingPIG }
                if isCapture { freshnessStrip }
                ObsTimeField(time: $time)
                futureTimeStrip
                weatherSection
                noteField
                if isCapture { receiptRow; commitButton }
            }
            .padding(Metric.screenPadding)
        }
        .accessibilityIdentifier(isCapture ? "capture-sheet" : "edit-sheet")
    }

    /// What this reading currently comes to, live as the steppers move — so the
    /// operator sees the consequence of the numbers before committing them.
    private var pendingPIG: some View {
        let pending = model.pendingObs(at: time)
        return HStack(alignment: .firstTextBaseline) {
            Text("Pending obs").fieldLabel()
            Spacer()
            Text("→ PIG \(pending.estimate.unshaded.probabilityOfIgnition) / \(pending.estimate.shaded.probabilityOfIgnition)")
                .font(PlateworksFont.label).kerning(0.4)
                .foregroundStyle(PlateworksColor.accent)
                .accessibilityIdentifier("pending-pig")
        }
    }

    private func editPreamble(_ obs: WeatherObs) -> some View {
        Text("Correcting the \(obs.timeLabel()) reading — recomputes PIG. Neighboring broadcasts are unchanged.")
            .font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Capture binds the shared weather; edit keeps its own, so correcting a
    /// record can never move the live estimate on the Ignition tab.
    @ViewBuilder private var weatherSection: some View {
        if isCapture {
            WeatherInputGroup(model: ignition, sharedWith: "Ignition", showsDerivedHumidity: false)
        } else {
            HStack(spacing: 10) {
                StepperCard(label: "Dry bulb", unit: "°F", value: $dryBulb, range: 10...130)
                // Fixed to how the reading was taken: a slung obs edits its wet
                // bulb (RH re-derives against the obs's own band); a direct obs
                // edits RH.
                if editingObs?.rhSource == .wetBulb {
                    StepperCard(label: "Wet bulb", unit: "°F", value: $wetBulb, range: 10...130)
                } else {
                    StepperCard(label: "Rel. humidity", unit: "%", value: $rh, range: 0...100)
                }
            }
            HStack(spacing: 10) {
                StepperCard(label: "Wind low", unit: "mph", value: $windLow, range: 0...60)
                StepperCard(label: "Wind high", unit: "mph", value: $windHigh, range: 0...60)
            }
            if windHigh > 0 {
                StepperCard(label: "Gust", unit: "mph", value: $gust, range: 0...80)
                ChipPicker(title: "Wind from", options: Wind.Direction.allCases,
                           selection: $direction, label: \.abbreviation)
            }
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Note").fieldLabel()
            TextField("Note (optional) — e.g. sun on thermometer", text: $note, axis: .vertical)
                .font(PlateworksFont.body)
                .lineLimit(1...3)
                .padding(11)
                .background(PlateworksColor.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PlateworksColor.hairline))
                .accessibilityIdentifier(isCapture ? "obs-note" : "edit-obs-note")
        }
    }

    /// How fresh the dry-bulb / RH reading is, so a fresh timestamp can't quietly
    /// freeze hours-old weather. Always present at a fixed height.
    private var freshnessStrip: some View {
        let stale = model.isPendingWeatherStale()
        let ageMinutes = model.pendingWeatherAge().map { Int($0 / 60) }
        return StatusStrip(
            icon: stale ? "exclamationmark.triangle.fill" : "clock",
            message: freshnessText(stale: stale, ageMinutes: ageMinutes),
            caution: stale,
            actionTitle: stale ? "Mark current" : nil,
            action: stale ? { model.confirmPendingWeatherCurrent() } : nil,
            identifier: "weather-freshness",
            actionIdentifier: "mark-weather-current")
    }

    private func freshnessText(stale: Bool, ageMinutes: Int?) -> String {
        guard let ageMinutes else { return "Weather not read yet" }
        if stale { return "Weather read \(ageMinutes) min ago — confirm current" }
        return ageMinutes == 0 ? "Weather just read" : "Weather read \(ageMinutes) min ago"
    }

    /// A time ahead of the clock would file the reading under an IRPG band that
    /// hasn't happened and make it the "latest" obs the hero and countdown read
    /// from. Back-filling a past time is legitimate and stays silent.
    ///
    /// The action is a plain acknowledgment, not a fix: a deliberately future
    /// time is the operator's call (pre-staging the top-of-hour obs), so the
    /// button dismisses the caution and leaves the time exactly as set.
    @ViewBuilder private var futureTimeStrip: some View {
        if time.timeIntervalSince(isCapture ? now : Date()) > 60, time != acknowledgedFutureTime {
            StatusStrip(
                icon: "clock.badge.exclamationmark",
                message: isCapture
                    ? "Obs time is ahead of the clock — this reading would be filed in the future."
                    : "That time is ahead of the clock — this reading would be filed in the future.",
                caution: true, actionTitle: "That's okay",
                action: { acknowledgedFutureTime = time },
                identifier: isCapture ? "obs-time-future" : "edit-time-future",
                actionIdentifier: isCapture ? "obs-time-ok" : "edit-time-ok")
        }
    }

    // MARK: - Commit

    /// Everything the commit will freeze, immediately above the button that does
    /// it — see ``WeatherWatchModel/freezeReceipt(at:wind:calendar:)``.
    private var receiptRow: some View {
        let receipt = model.freezeReceipt(at: time, wind: ignition.wind)
        return VStack(alignment: .leading, spacing: 3) {
            Text("Freezes").fieldLabel()
            Text(receipt.display)
                .font(PlateworksFont.labelSmall)
                .foregroundStyle(PlateworksColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("freeze-receipt")
                .accessibilityLabel(receipt.spoken)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlateworksColor.surfaceSunk, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PlateworksColor.hairline))
    }

    private var commitButton: some View {
        Button { commit() } label: {
            HStack(spacing: 10) {
                Text("Log Observation")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("· \(formatHourMinute(time))")
                    .font(PlateworksFont.label).monospacedDigit().opacity(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(PlateworksColor.accent, in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("log-observation")
    }

    private func commit() {
        let obs = model.logObs(at: time, wind: ignition.wind,
                               note: note.isEmpty ? nil : note)
        logged = obs
        onLogged(obs)
    }

    private func save() {
        guard let obs = editingObs else { return }
        model.updateObs(id: obs.id, timestamp: time, dryBulbF: dryBulb,
                        relativeHumidity: rh, wetBulbF: wetBulb,
                        wind: editedWind, note: note)
        onSaved()
        dismiss()
    }

    /// Rebuild the edited wind, mirroring `IgnitionModel.wind` (no high speed ⇒
    /// light/variable, still carrying any gust) — but preserve "not recorded"
    /// (`nil`) for an obs that never had wind and still has none entered, so a
    /// dry-bulb-only correction can't fabricate a light-and-variable broadcast.
    private var editedWind: Wind? {
        let g = gust > 0 ? gust : nil
        guard windHigh > 0 else {
            return (editingObs?.wind == nil && g == nil) ? nil : .lightVariable(gust: g)
        }
        return .measured(Wind.SpeedRange(low: min(windLow, windHigh), high: windHigh),
                         direction, gust: g)
    }

    // MARK: - Success: the script, big

    /// What the operator needs the instant a reading is frozen — the script that
    /// goes out over the net — instead of a dismissal that drops them at the
    /// bottom of the record with the broadcast panel somewhere above.
    ///
    /// This *presents* the already-frozen ``WeatherObs/broadcastText``; it does
    /// not recompute anything.
    private func successScreen(_ obs: WeatherObs) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.cardSpacing) {
                StatusStrip(icon: "checkmark.circle.fill",
                            message: "Logged \(obs.timeLabel()) — read this over the net",
                            identifier: "log-confirmed")
                Text(model.broadcastScript(for: obs))
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(PlateworksColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(PlateworksColor.surface, in: RoundedRectangle(cornerRadius: Metric.cardRadius))
                    .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius)
                        .strokeBorder(PlateworksColor.hairline))
                    .accessibilityIdentifier("broadcast-success")
                // In the scroll, not a bottom inset — same reason as the form's
                // commit: inset contents don't surface to XCUITest here.
                Button { copyToPasteboard(model.broadcastScript(for: obs)) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy script").font(PlateworksFont.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: Metric.tapTarget)
                    .background(PlateworksColor.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(PlateworksColor.accent, lineWidth: 1.5))
                    .foregroundStyle(PlateworksColor.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("copy-broadcast-success")
                Text("PIG is app-computed — not observed, not a forecast.")
                    .font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
            }
            .padding(Metric.screenPadding)
        }
    }
}

/// The observation-time control: tap the value to **type** a time directly
/// ("1435" or "14:35"), or nudge it ±5 minutes. Two-way bound to the timestamp,
/// so typing, nudging, and the reset-to-now all agree.
@MainActor
struct ObsTimeField: View {
    @Binding var time: Date
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Obs time").fieldLabel()
            HStack(spacing: 8) {
                TextField("HH:MM", text: $text)
                    .readout(32, weight: .bold)
                    // .numbersAndPunctuation, not .numberPad: the field accepts
                    // "14:35" as well as "1435", and the number pad has no colon.
                    .fieldKeyboard(.signedNumber)
                    .frame(maxWidth: 92)
                    .accessibilityIdentifier("obs-time-field")
                    .onChange(of: text) { _, v in
                        if let hm = parseHourMinute(v) { time = settingHourMinute(time, hm.0, hm.1) }
                    }
                Spacer(minLength: 6)
                nudge("−5m", -5)
                nudge("+5m", 5)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlateworksColor.surface, in: RoundedRectangle(cornerRadius: Metric.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius).strokeBorder(PlateworksColor.hairline))
        .onAppear { text = formatHourMinute(time) }
        .onChange(of: time) { _, t in
            // Resync the field when the time changed from a nudge or an
            // auto-seed — but not from the user's own typing (parse matches).
            let c = Calendar.current.dateComponents([.hour, .minute], from: t)
            let parsed = parseHourMinute(text)
            if parsed?.0 != c.hour || parsed?.1 != c.minute { text = formatHourMinute(t) }
        }
        .accessibilityIdentifier("obs-time")
    }

    private func nudge(_ label: String, _ minutes: Int) -> some View {
        Button { time = shiftingMinutes(time, minutes) } label: {
            Text(label)
                .font(PlateworksFont.labelSmall).fontWeight(.bold)
                .foregroundStyle(PlateworksColor.ink)
                .frame(minWidth: 46, minHeight: Metric.tapTarget)
                .background(PlateworksColor.surfaceSunk, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// Parse `"HH:MM"` / `"HHMM"` / `"H"` into clamped (hour, minute), or nil if the
/// text doesn't yield a valid clock time (so a half-typed field leaves the time
/// alone).
func parseHourMinute(_ s: String) -> (Int, Int)? {
    let cleaned = s.filter { $0.isNumber || $0 == ":" }
    // A bare ":" (or any digitless string) must not parse: Int("") ?? 0 would
    // read it as 00:00 and silently re-time the observation to midnight — a
    // past time, so the future-time strip would never flag it.
    guard cleaned.contains(where: \.isNumber) else { return nil }
    var h = 0, m = 0
    if cleaned.contains(":") {
        let parts = cleaned.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        h = Int(parts[0]) ?? 0
        m = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
    } else {
        let digits = cleaned.filter { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        if digits.count <= 2 {
            h = Int(digits) ?? 0
        } else {
            h = Int(digits.prefix(digits.count - 2)) ?? 0
            m = Int(digits.suffix(2)) ?? 0
        }
    }
    guard (0...23).contains(h), (0...59).contains(m) else { return nil }
    return (h, m)
}

func formatHourMinute(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

func settingHourMinute(_ base: Date, _ h: Int, _ m: Int) -> Date {
    Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
}

func shiftingMinutes(_ base: Date, _ minutes: Int) -> Date {
    Calendar.current.date(byAdding: .minute, value: minutes, to: base) ?? base
}
