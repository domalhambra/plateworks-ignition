import SwiftUI
import PlateworksCore

/// The Ignition screen. A pinned PIG summary keeps the result on screen at all
/// times; below it the inputs are chunked into the IRPG worksheet's own sections
/// — Weather (Table A), Calendar · Time (Tables B/C/D), and Site (corrections) —
/// followed by the calculation chain and both shaded/unshaded results with a
/// plain-language interpretation. Everything updates live.
@MainActor
struct IgnitionView: View {
    @Bindable var model: IgnitionModel
    /// Whether the Obs tab's site gate is still up — mirrored here so the two
    /// tabs' start bars always show the same state.
    var obsGated: Bool = false
    /// Hands off to the Obs tab (and opens the capture form past the gate).
    /// `nil` hides the bar — previews and any host without a tab shell.
    var onStartObservation: (() -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.sectionSpacing) {
                header
                weatherSection
                calendarTimeSection
                siteSection
                resultsSection
            }
            .padding(Metric.screenPadding)
        }
        .safeAreaInset(edge: .top, spacing: 0) { summaryBar }
        // The same start bar the Obs tab pins, so the capture flow's entry
        // point exists wherever the operator happens to be — dialing in weather
        // here shouldn't require knowing the log lives one tab over.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let onStartObservation {
                StartObservationBar(gated: obsGated, tappableWhileGated: true,
                                    identifier: "start-observation",
                                    action: onStartObservation)
            }
        }
        .background(PlateworksColor.background)
        // No navigation bar: the app has no push navigation, the tab bar names
        // the screen, and the in-content header names it again — the system bar
        // contributed only dead space above the pinned PIG summary, with a
        // stray large-title "Ignition" materializing on scroll. Hiding it moves
        // the headline number to the top edge; the summary bar's surface color
        // extends under the status bar via `background`'s default safe-area
        // bleed. The NavigationStack shell stays for sheets and any future push.
        .toolbar(.hidden, for: .navigationBar)
        // Keeps month/time tracking the wall clock across a long shift; the model
        // ignores ticks once the operator overrides either picker. A `.task` loop
        // rather than an autoconnected `Timer.publish`, which kept a run-loop
        // source alive — and re-evaluated this body every minute — for the whole
        // life of the view, including while the Ignition tab was off screen.
        .task {
            while !Task.isCancelled {
                model.refreshClock()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshClock() }
        }
    }

    // MARK: - Pinned summary

    /// The always-visible headline result, pinned above the scroll so the PIG is
    /// never below the fold no matter how far down the inputs the operator is.
    private var summaryBar: some View {
        let e = model.estimate
        let s = model.sensitivity
        let behavior = e.unshaded.interpretation
        let wind = model.wind
        return PIGSummaryBar(
            temperatureF: model.dryBulbF,
            relativeHumidity: model.effectiveRelativeHumidity,
            windText: wind.spotString,
            windSpoken: wind.spokenPhrase,
            unshadedPIG: e.unshaded.probabilityOfIgnition,
            unshadedColor: behavior.color,
            unshadedEnvelope: s.unshaded,
            shadedPIG: e.shaded.probabilityOfIgnition,
            shadedColor: e.shaded.interpretation.color,
            shadedEnvelope: s.shaded,
            behaviorWord: behavior.title,
            behaviorColor: behavior.color)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Ignition").font(PlateworksFont.title).foregroundStyle(PlateworksColor.ink)
            Spacer()
            Text("IRPG p.44–49").fieldLabel()
        }
    }

    // MARK: - Weather (IRPG Table A)

    /// The weather inputs in a bounded panel so switching humidity source resizes
    /// one block rather than shoving the sections below it. Carries the shared cue
    /// — this same weather is what the Watch tab logs.
    private var weatherSection: some View {
        WeatherInputGroup(model: model, sharedWith: "Obs", showsDerivedHumidity: true)
            .padding(Metric.cardSpacing)
            .background(PlateworksColor.surfaceSunk, in: RoundedRectangle(cornerRadius: Metric.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius).strokeBorder(PlateworksColor.hairline))
    }

    // MARK: - Calendar · Time (Tables B/C/D)

    private var calendarTimeSection: some View {
        VStack(alignment: .leading, spacing: Metric.cardSpacing) {
            SectionHeader(title: "Calendar · Time", annotation: "Tables B/C/D")
            monthPicker
            ChipPicker(title: "Time of day", options: TimeOfDay.allCases,
                       selection: $model.timeOfDay, label: \.label)
            clockStrip
        }
    }

    private var monthPicker: some View {
        ChipPicker(title: "Month  ·  \(model.estimate.input.monthGroup.letter) (\(model.estimate.input.monthGroup.monthsDescription))",
                   options: Array(1...12), selection: $model.month,
                   label: { Month.shortNames[$0 - 1] })
    }

    /// The always-present clock annunciator: nominal while month/time track the
    /// wall clock, amber and tappable once the operator has overridden them — so a
    /// stale night/day rule is never silent, and the row never shifts the layout.
    @ViewBuilder private var clockStrip: some View {
        if model.clockOverridden {
            StatusStrip(icon: "clock.arrow.circlepath",
                        message: "Month/time set manually — tap to resume tracking the clock",
                        caution: true,
                        rowTapAction: { model.resumeAutoClock() },
                        identifier: "clock-override-notice")
        } else {
            StatusStrip(icon: "clock",
                        message: "Tracking clock · \(Month.shortNames[model.month - 1]) · \(model.timeOfDay.label)",
                        identifier: "clock-status")
        }
    }

    // MARK: - Site (corrections)

    private var siteSection: some View {
        VStack(alignment: .leading, spacing: Metric.cardSpacing) {
            SectionHeader(title: "Site", annotation: "Corrections")
            HStack(alignment: .top, spacing: 10) {
                ChipPicker(title: "Aspect", options: Aspect.allCases,
                           selection: $model.aspect, label: \.rawValue)
                ChipPicker(title: "Slope", options: Slope.allCases,
                           selection: $model.slope, label: \.displayName)
            }
            ChipPicker(title: "Elevation vs. weather site", options: ElevationDelta.allCases,
                       selection: $model.elevationDelta, label: \.displayName)
        }
    }

    // MARK: - Results & work

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: Metric.cardSpacing) {
            chainStrip
            results
            interpretation
            disclaimer
        }
    }

    private var chainStrip: some View {
        let e = model.estimate
        return HStack(spacing: 0) {
            chainNode("REF FM", "\(e.referenceFuelMoisture)")
            chainArrow
            chainNode("CORR", e.isNight ? "night +5"
                      : "\(e.unshaded.correction ?? 0)/\(e.shaded.correction ?? 0)")
            chainArrow
            chainNode("FFM", "\(e.unshaded.fineFuelMoisture)/\(e.shaded.fineFuelMoisture)%")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(PlateworksColor.surfaceSunk, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PlateworksColor.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calc-chain")
    }

    private func chainNode(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(label).font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
            Text(value).font(.system(.footnote, design: .monospaced).weight(.bold))
                .foregroundStyle(PlateworksColor.ink)
        }
        .frame(maxWidth: .infinity)
    }

    private var chainArrow: some View {
        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(PlateworksColor.muted.opacity(0.6))
    }

    private var results: some View {
        let e = model.estimate
        let s = model.sensitivity
        // Top-aligned so expanding one card's firmness detail doesn't re-center
        // the other.
        return HStack(alignment: .top, spacing: 10) {
            ResultCard(title: "Unshaded", pig: e.unshaded.probabilityOfIgnition,
                       severity: e.unshaded.interpretation.color,
                       subtitle: "FFM \(e.unshaded.fineFuelMoisture)% · <50% shade",
                       sensitivity: s.unshaded, toleranceSummary: s.toleranceSummary)
            ResultCard(title: "Shaded", pig: e.shaded.probabilityOfIgnition,
                       severity: e.shaded.interpretation.color,
                       subtitle: "FFM \(e.shaded.fineFuelMoisture)% · ≥50% shade",
                       sensitivity: s.shaded, toleranceSummary: s.toleranceSummary)
        }
    }

    private var interpretation: some View {
        // Lead with the more hazardous (unshaded) interpretation.
        let behavior = model.estimate.unshaded.interpretation
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(behavior.color).frame(width: 9, height: 9)
                Text(behavior.title).font(PlateworksFont.body.weight(.semibold)).foregroundStyle(PlateworksColor.ink)
                Text(behavior.pigRangeLabel).font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
            }
            Text(behavior.detail).font(.footnote).foregroundStyle(PlateworksColor.ink.opacity(0.85))
            Text(FireBehaviorInterpretation.caution + "  IRPG p.49")
                .font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted).italic()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlateworksColor.surfaceSunk, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PlateworksColor.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("interpretation")
    }

    private var disclaimer: some View {
        Text("Decision support only — not affiliated with or endorsed by NWCG. Verify against your IRPG.")
            .font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }
}
