import SwiftUI
import PlateworksCore

/// The shared **weather** inputs — humidity source, dry bulb, and either a direct
/// RH or a wet bulb (with its elevation band, Alaska thresholds, and the derived
/// psychrometrics). Both the Ignition screen and the Watch capture card render
/// *these exact controls bound to the same* ``IgnitionModel``, so extracting them
/// here keeps the two screens from drifting and lets the "shared with the other
/// tab" cue stay honest.
///
/// The wet-bulb-only extras (elevation band + derived readouts) sit at the end of
/// the group and animate in place, so switching humidity source resizes this one
/// bounded block instead of inserting rows that shove the rest of the screen.
///
/// This group absorbed the standalone Humidity screen: sling a psychrometer,
/// switch the source to *From wet bulb*, and the RH, dew point, and wet-bulb
/// depression appear right where the reading was entered — no second tab, no
/// hand-off to re-type.
@MainActor
struct WeatherInputGroup: View {
    @Bindable var model: IgnitionModel
    /// The other tab these inputs are shared with, shown as a passive cue in the
    /// section header (e.g. "Obs" on Ignition, "Ignition" on Obs). Pass `nil`
    /// to omit the header entirely.
    var sharedWith: String? = nil
    /// Whether to show the read-only derived psychrometrics (RH, dew point,
    /// wet-bulb depression) and the Alaska threshold toggle in wet-bulb mode.
    /// Ignition shows them — the RH is the value flowing into the PIG chain, and
    /// this is where the belt-weather-kit reading gets read off. The Watch
    /// capture card keeps its footprint tighter and omits them; its band chips
    /// still respect the Alaska setting, they just don't carry the switch.
    var showsDerivedHumidity: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.cardSpacing) {
            if let sharedWith {
                SectionHeader(title: "Weather", annotation: "IRPG Table A", sharedWith: sharedWith)
            }
            ChipPicker(title: "Humidity source", options: RHSource.allCases,
                       selection: $model.rhSource, label: \.displayName)
            HStack(spacing: 10) {
                StepperCard(label: "Dry bulb", unit: "°F",
                            value: $model.dryBulbF, range: 10...130)
                if model.rhSource == .direct {
                    StepperCard(label: "Rel. humidity", unit: "%",
                                value: $model.relativeHumidity, range: 0...100)
                } else {
                    StepperCard(label: "Wet bulb", unit: "°F",
                                value: $model.wetBulbF, range: 10...130)
                }
            }
            if model.rhSource == .wetBulb {
                elevationBandPicker
                if showsDerivedHumidity {
                    alaskaToggle
                    if let result = model.derivedHumidity { derivedReadouts(result) }
                }
            }
            windControls
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.rhSource)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.windSpeedHigh > 0)
    }

    /// The station-pressure band. Its chips carry Alaska or CONUS elevation
    /// ranges depending on the toggle below, on both screens this group renders
    /// on — the Watch capture card omits the switch, not the relabelling.
    ///
    /// `alaska` is read here and captured by value: `ChipPicker` stores this
    /// label closure and calls it outside the model's actor context.
    private var elevationBandPicker: some View {
        let alaska = model.alaska
        return ChipPicker(
            title: "Elevation band  ·  \(Int(model.elevationBand.stationPressureInHg)) inHg",
            options: ElevationBand.allCases,
            selection: $model.elevationBand,
            label: { IgnitionModel.bandLabel($0, alaska: alaska) })
    }

    /// The Alaska elevation thresholds, sitting with the band row it relabels —
    /// the band chips above re-caption the moment it flips. It changes no
    /// arithmetic (``Psychrometrics`` takes the band, not an elevation), which is
    /// why it belongs beside the labels rather than near the results.
    private var alaskaToggle: some View {
        Toggle(isOn: $model.alaska) {
            Text("Alaska elevation thresholds")
                .font(PlateworksFont.body).foregroundStyle(PlateworksColor.ink)
        }
        .tint(PlateworksColor.accent)
        .padding(.horizontal, 14)
        .frame(minHeight: Metric.tapTarget)
        .background(PlateworksColor.surface, in: RoundedRectangle(cornerRadius: Metric.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius).strokeBorder(PlateworksColor.hairline))
        .accessibilityIdentifier("alaska-toggle")
    }

    /// Observed wind, entered as a low–high speed range (e.g. 3–6 mph; set both
    /// equal for a single value, both 0 for light/variable). Above 0 the gust and
    /// compass appear — contained, so the rest of the group doesn't jump. Wind is
    /// recorded on the reading, not used by PIG.
    @ViewBuilder private var windControls: some View {
        HStack(spacing: 10) {
            StepperCard(label: "Wind low", unit: "mph", value: $model.windSpeedLow, range: 0...60)
            StepperCard(label: "Wind high", unit: "mph", value: $model.windSpeedHigh, range: 0...60)
        }
        if model.windSpeedHigh > 0 {
            StepperCard(label: "Gust", unit: "mph", value: $model.windGustMPH, range: 0...80)
            ChipPicker(title: "Wind from", options: Wind.Direction.allCases,
                       selection: $model.windDirection, label: \.abbreviation)
        }
    }

    /// The RH the sling reading yields, read off where it was entered: read-only,
    /// brand teal, kept visually primary because it is the value flowing into the
    /// PIG chain.
    ///
    /// Dew point and wet-bulb depression used to sit directly under this readout.
    /// They fall out of the same computation but feed nothing downstream and are
    /// rarely read on the line, so they now have their own section at the foot of
    /// the Ignition screen — see ``IgnitionView`` `slingDetailSection`. What stays
    /// here is only what the calculation actually consumes. The Watch capture card
    /// never carried either (its `showsDerivedHumidity` is false).
    private func derivedReadouts(_ result: HumidityResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rel. humidity").fieldLabel()
                    Text("computed from wet bulb")
                        .font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(result.relativeHumidity)").readout(32).foregroundStyle(PlateworksColor.accent)
                    Text("%").readout(18).foregroundStyle(PlateworksColor.accent)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("derived-rh")
            .accessibilityLabel("Relative humidity from wet bulb")
            .accessibilityValue("\(result.relativeHumidity) percent")

            Text("Psychrometric estimate — verify against your belt weather kit tables.")
                .font(PlateworksFont.labelSmall).foregroundStyle(PlateworksColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(PlateworksColor.surface, in: RoundedRectangle(cornerRadius: Metric.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius).strokeBorder(PlateworksColor.hairline))
    }
}
