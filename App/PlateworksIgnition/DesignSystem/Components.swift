import SwiftUI
import PlateworksCore

/// A large stepper input card: mono label, big tabular value, and −/+ buttons
/// sized for gloved hands. Tapping the value also allows direct entry.
struct StepperCard: View {
    let label: String
    let unit: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).fieldLabel()
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(value)").readout(32, weight: .bold).foregroundStyle(PlateworksColor.ink)
                Text(unit).font(PlateworksFont.body).foregroundStyle(PlateworksColor.muted)
            }
            HStack(spacing: 8) {
                stepButton("minus") { adjust(-step) }
                stepButton("plus") { adjust(step) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlateworksColor.surface, in: RoundedRectangle(cornerRadius: Metric.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius).strokeBorder(PlateworksColor.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(label)
        .accessibilityLabel(label)
        .accessibilityValue("\(value) \(unit)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(step)
            case .decrement: adjust(-step)
            @unknown default: break
            }
        }
    }

    private func adjust(_ delta: Int) {
        value = min(max(value + delta, range.lowerBound), range.upperBound)
    }

    private func stepButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: Metric.tapTarget)
                .background(PlateworksColor.surfaceSunk, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(PlateworksColor.ink)
        }
        .buttonStyle(.plain)
    }
}

/// What a text field needs its keyboard to be able to produce.
///
/// Named by capability rather than by UIKit type so the choice is reviewable:
/// `.numberPad` has **no minus sign**, which silently makes a field unable to
/// accept a negative value — the bug that stopped a site elevation below sea
/// level (Badwater Basin is −282 ft) from being enterable at all.
enum FieldKeyboard {
    case text
    /// Whole numbers, no sign — counts and other never-negative values.
    case unsignedInteger
    /// Signed and/or fractional values: elevations below sea level, decimal
    /// latitude and longitude.
    case signedNumber
}

extension View {
    /// Apply a field keyboard. Keyboard types are iOS-only; on macOS this is a
    /// no-op so shared views compile for both destinations.
    @ViewBuilder func fieldKeyboard(_ kind: FieldKeyboard) -> some View {
        #if os(iOS)
        switch kind {
        case .text: self.keyboardType(.default)
        case .unsignedInteger: self.keyboardType(.numberPad)
        case .signedNumber: self.keyboardType(.numbersAndPunctuation)
        }
        #else
        self
        #endif
    }
}

/// A read-only stat card (e.g. dew point, wet-bulb depression).
struct StatCard: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).fieldLabel()
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).readout(32, weight: .bold).foregroundStyle(PlateworksColor.ink)
                Text(unit).font(PlateworksFont.body).foregroundStyle(PlateworksColor.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlateworksColor.surface, in: RoundedRectangle(cornerRadius: Metric.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius).strokeBorder(PlateworksColor.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(label)
        .accessibilityLabel(label)
        .accessibilityValue("\(value) \(unit)")
    }
}

/// A single-select chip row for a `CaseIterable` enum of options.
struct ChipPicker<Option: Hashable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fieldLabel()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        let selected = option == selection
                        Button {
                            selection = option
                        } label: {
                            Text(label(option))
                                .font(PlateworksFont.labelSmall)
                                .kerning(0.4)
                                .padding(.horizontal, 11).padding(.vertical, 8)
                                .background(
                                    selected ? PlateworksColor.accent.opacity(0.16) : PlateworksColor.surface,
                                    in: Capsule())
                                .overlay(Capsule().strokeBorder(
                                    selected ? PlateworksColor.accent : PlateworksColor.hairline,
                                    lineWidth: selected ? 1.5 : 1))
                                .foregroundStyle(selected ? PlateworksColor.accent : PlateworksColor.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(label(option))
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A labeled group heading — uppercase mono title, an optional table-reference
/// annotation, and an optional "shared with another tab" cue. Used to chunk the
/// Ignition inputs into the IRPG worksheet's own sections (Weather / Calendar ·
/// Time / Site) so the screen reads as distinct steps rather than one long list.
struct SectionHeader: View {
    let title: String
    var annotation: String? = nil
    /// When set, appends a passive "SHARED · <tab>" cue signaling that the
    /// controls under this header are the same model the named tab edits — so an
    /// operator is never surprised that weather typed here shows up there.
    var sharedWith: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).fieldLabel()
            if let annotation {
                Text("· \(annotation)").fieldLabel()
            }
            Spacer(minLength: 8)
            if let sharedWith {
                HStack(spacing: 3) {
                    Image(systemName: "link")
                    Text("SHARED · \(sharedWith.uppercased())")
                }
                .font(PlateworksFont.labelSmall)
                .kerning(0.4)
                .foregroundStyle(PlateworksColor.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Weather inputs are shared with the \(sharedWith) tab; edits apply everywhere.")
            }
        }
    }
}

/// The app's **status annunciator** — a permanently present single-line row whose
/// content and tint change with state, but whose presence and reserved height
/// never do. Replaces the old come-and-go clock-override notice and weather
/// freshness row, both of which shifted the layout as they appeared. `Muted` for
/// nominal state, `SignalAmber` for caution; never a severity color (severity is
/// fire behavior, not app state).
struct StatusStrip: View {
    let icon: String
    let message: String
    /// Caution state — renders in `SignalAmber` instead of `Muted`.
    var caution: Bool = false
    /// Optional trailing capsule action (e.g. "Mark current").
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    /// When set, the whole row is tappable (e.g. tap to resume the clock).
    var rowTapAction: (() -> Void)? = nil
    /// Accessibility identifier for the row (or its whole-row button).
    var identifier: String = "status-strip"
    /// Accessibility identifier for the trailing action button.
    var actionIdentifier: String? = nil

    /// Reserved height, scaled with Dynamic Type so the row still holds constant
    /// height across states at any text size.
    @ScaledMetric(relativeTo: .caption) private var minHeight: CGFloat = Metric.statusStripHeight

    private var tint: Color { caution ? PlateworksColor.caution : PlateworksColor.muted }

    var body: some View {
        let strip = HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(message).font(PlateworksFont.labelSmall).lineLimit(2).minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(PlateworksFont.labelSmall).fontWeight(.bold)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .overlay(Capsule().strokeBorder(tint, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(actionIdentifier ?? "status-strip-action")
            }
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        .contentShape(Rectangle())

        if let rowTapAction {
            Button(action: rowTapAction) { strip }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier)
        } else {
            strip
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// A compact, always-visible headline pinned above the Ignition inputs so the
/// reading never scrolls out of sight. Two tiers: the current **reading** —
/// temperature, RH, and wind — over the **result** — both PIG shadings (each in
/// its severity color, with an underbar that echoes ``ResultCard``'s stripe and,
/// like it, warms toward the neighbouring band on a cell edge) plus the unshaded
/// fire-behavior word. Read-only; the full result cards below carry the detail.
struct PIGSummaryBar: View {
    let temperatureF: Int
    let relativeHumidity: Int
    /// Compact wind, e.g. `"SW 4-6"`, `"Calm"`, `"N 3-5 Gust 12"`.
    let windText: String
    /// Spoken wind for VoiceOver, e.g. `"4-6 miles per hour from the Southwest"`.
    let windSpoken: String
    let unshadedPIG: Int
    let unshadedColor: Color
    let unshadedEnvelope: Sensitivity.Envelope?
    let shadedPIG: Int
    let shadedColor: Color
    let shadedEnvelope: Sensitivity.Envelope?
    let behaviorWord: String
    let behaviorColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                weatherNode("TEMP", "\(temperatureF)", "°F")
                weatherNode("RH", "\(relativeHumidity)", "%")
                weatherNode("WIND", windText, nil)
            }
            HStack(alignment: .center, spacing: 16) {
                reading("UNSH", unshadedPIG, unshadedColor, unshadedEnvelope)
                reading("SHD", shadedPIG, shadedColor, shadedEnvelope)
                Spacer(minLength: 8)
                Text(behaviorWord.uppercased())
                    .font(PlateworksFont.label).kerning(0.4)
                    .foregroundStyle(behaviorColor)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, Metric.screenPadding)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .background(PlateworksColor.surface)
        .overlay(alignment: .bottom) { PlateworksColor.hairline.frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("pig-summary")
        .accessibilityLabel("Current reading and probability of ignition")
        .accessibilityValue("Temperature \(temperatureF) degrees Fahrenheit, humidity \(relativeHumidity) percent, wind \(windSpoken). Unshaded \(unshadedPIG) percent, shaded \(shadedPIG) percent. \(behaviorWord).")
    }

    /// One reading-tier stat (temp / RH / wind), evenly sharing the row.
    private func weatherNode(_ label: String, _ value: String, _ unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).readout(18, minimumScale: 0.6).foregroundStyle(PlateworksColor.ink)
                if let unit {
                    Text(unit).font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reading(_ label: String, _ pig: Int, _ color: Color,
                         _ env: Sensitivity.Envelope?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label).font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(pig)").readout(26).foregroundStyle(color)
                    Text("%").readout(15).foregroundStyle(color)
                }
            }
            RoundedRectangle(cornerRadius: 1.5)
                .fill(underbarStyle(color, env))
                .frame(width: 56, height: 3)
        }
    }

    /// Solid severity when firm; a subtle current→neighbour gradient on a band
    /// edge — the horizontal echo of ``ResultCard``'s Layer-1 stripe.
    private func underbarStyle(_ color: Color, _ env: Sensitivity.Envelope?) -> AnyShapeStyle {
        if let nb = env?.notable {
            return AnyShapeStyle(LinearGradient(
                colors: [color, nb.band.color], startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(color)
    }
}

/// The pinned bottom "Start an Observation" bar, shared by both tabs so the
/// entry point to the capture flow looks identical wherever the operator is.
/// On **Obs** it opens the capture sheet directly and is disabled while the
/// site gate holds (the confirm strip is on the same screen). On **Ignition**
/// it hands off to the Obs tab instead — and stays tappable while gated,
/// because the site confirm it points at lives on the *other* tab and a dead
/// button there would be a dead end.
struct StartObservationBar: View {
    @Environment(\.colorScheme) private var scheme
    let gated: Bool
    /// `true` on Ignition (tap navigates to the gate), `false` on Obs
    /// (the gate disables the button in place).
    var tappableWhileGated = false
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(gated ? "Confirm site to start" : "Start an Observation")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(scheme == .dark ? Color.clear : PlateworksColor.accent,
                            in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    if scheme == .dark {
                        RoundedRectangle(cornerRadius: 16).strokeBorder(PlateworksColor.accent, lineWidth: 1.5)
                    }
                }
                .foregroundStyle(scheme == .dark ? PlateworksColor.accent : Color.white)
        }
        .buttonStyle(.plain)
        .disabled(gated && !tappableWhileGated)
        .opacity(gated && !tappableWhileGated ? 0.5 : 1)
        .accessibilityIdentifier(identifier)
        .padding(.horizontal, Metric.screenPadding)
        .padding(.top, 10).padding(.bottom, 8)
        .background(PlateworksColor.surface)
        .overlay(alignment: .top) { PlateworksColor.hairline.frame(height: 1) }
    }
}

/// The PIG result card: severity stripe, big tabular readout, and sub-line.
///
/// When a ``Sensitivity/Envelope`` is supplied it gains a **cell-edge marker**.
/// The IRPG tables are step functions, so a reading a step or two from a cell
/// edge can swing PIG by a whole fire-behavior band. The marker surfaces that in
/// three layers, and — critically — costs nothing to read when the number is
/// firm:
/// - **Layer 1 (always on):** the severity stripe stays solid when firm and
///   becomes a subtle gradient toward the neighbouring band when the plausible
///   envelope crosses one. A pre-attentive "this one's on the move" cue at zero
///   added height.
/// - **Layer 2 (reserved slot):** one amber caution line naming the notable
///   neighbour, in a fixed-height slot so the card never changes size as inputs
///   change (no input-driven jitter).
/// - **Layer 3 (tap to expand):** the full envelope and the band transition, for
///   crews who want to verify — matching the app's show-your-work ethic.
struct ResultCard: View {
    let title: String
    let pig: Int
    let severity: Color
    let subtitle: String
    /// The firmness envelope for this shading; `nil` disables the marker.
    var sensitivity: Sensitivity.Envelope? = nil
    /// The reading envelope explored, e.g. `"±2°F · ±3% RH"` (expanded detail).
    var toleranceSummary: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    /// Height of the reserved caption slot, scaled with Dynamic Type so the slot
    /// still fits (and still prevents jitter) at accessibility text sizes.
    @ScaledMetric(relativeTo: .caption2) private var captionSlotHeight: CGFloat = 16

    /// The neighbouring reading worth surfacing — present exactly when the
    /// envelope crosses a fire-behavior band.
    private var crossing: Sensitivity.Reading? { sensitivity?.notable }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fieldLabel()
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(pig)").readout(46).foregroundStyle(severity)
                Text("%").readout(22).foregroundStyle(severity)
            }
            Text(subtitle).font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
            edgeCaption
            if expanded, let env = sensitivity { firmnessDetail(env) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlateworksColor.surface, in: RoundedRectangle(cornerRadius: Metric.resultRadius))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: Metric.resultRadius,
                bottomLeadingRadius: Metric.resultRadius)
                .fill(stripeStyle)
                .frame(width: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: Metric.resultRadius).strokeBorder(PlateworksColor.hairline))
        .contentShape(Rectangle())
        .onTapGesture {
            guard sensitivity != nil else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: crossing)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("result-\(title)")
        .accessibilityLabel("\(title) probability of ignition")
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint(sensitivity != nil ? "Double tap for reading firmness detail" : "")
        .accessibilityAction(named: "Reading firmness detail") {
            if sensitivity != nil { expanded.toggle() }
        }
    }

    /// Layer 1 — solid when firm, a subtle current→neighbour gradient on an edge.
    private var stripeStyle: AnyShapeStyle {
        if let nb = crossing {
            return AnyShapeStyle(LinearGradient(
                colors: [severity, nb.band.color], startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(severity)
    }

    /// Layer 2 — one amber line in a fixed-height slot (empty when firm), so the
    /// card holds its size no matter how the inputs move. The slot only exists
    /// when a firmness envelope is supplied, so a plain ``ResultCard`` (e.g. the
    /// Watch hero, showing a frozen reading) is unchanged.
    @ViewBuilder private var edgeCaption: some View {
        if let env = sensitivity {
            ZStack(alignment: .leading) {
                Color.clear.frame(height: captionSlotHeight)
                if let nb = env.notable {
                    HStack(spacing: 3) {
                        Image(systemName: env.direction == .higher ? "arrow.up.forward" : "arrow.down.forward")
                        Text("COULD READ \(nb.pig)% · \(nb.descriptor)")
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .font(PlateworksFont.labelSmall)
                    .foregroundStyle(PlateworksColor.caution)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Layer 3 — the full envelope and the band transition (or reassurance).
    @ViewBuilder private func firmnessDetail(_ env: Sensitivity.Envelope) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(PlateworksColor.hairline).frame(height: 1).padding(.top, 4)
            Text("Reading firmness").fieldLabel()
            Text("PIG \(env.pigLow)–\(env.pigHigh)%" + (toleranceSummary.map { " over \($0)" } ?? ""))
                .font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.ink)
            if let nb = env.notable {
                Text("\(env.baselineBand.title) → \(nb.band.title) at \(nb.descriptor)")
                    .font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
            } else {
                Text("Band holds — firm.")
                    .font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var accessibilityValueText: String {
        var v = "\(pig) percent. \(subtitle)"
        if let env = sensitivity, let nb = crossing {
            let dir = env.direction == .higher ? "higher" : "lower"
            v += ". Near a band edge — could read \(nb.pig) percent, \(nb.band.title), \(dir), at \(nb.descriptor)"
        }
        return v
    }
}
