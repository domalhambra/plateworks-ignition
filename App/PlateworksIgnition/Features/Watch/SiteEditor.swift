import SwiftUI
import PlateworksCore

/// The **Site & radio** block of the Obs screen: the once-per-shift site review
/// gate, the IMET header fields, and the site position (elevation + coordinate).
///
/// Extracted from `WatchView` — which had grown past 900 lines — so the position
/// entry, its GPS autofill, and the validation around both live in one reviewable
/// place.
///
/// ### Position entry
/// The position can be filled from a one-shot GPS fix or typed, and typing always
/// wins: any hand edit to the elevation or either coordinate field flips
/// ``WeatherWatchModel/siteSource`` back to `.manual` and drops the fix
/// provenance. There is no mode to switch and nothing to unlock — the GPS button
/// fills the same fields the operator can already edit.
///
/// The elevation is not cosmetic: it picks the ``ElevationBand`` that supplies
/// the station pressure for the sling-RH derivation, so it reaches the PIG. A
/// GPS-derived elevation is therefore rounded to 100 ft by ``SiteElevation`` and
/// checked against the band boundaries, and a fix whose uncertainty straddles one
/// is called out for map confirmation rather than quietly trusted.
@MainActor
struct SiteEditor: View {
    @Bindable var model: WeatherWatchModel
    /// The shared site factors (aspect, slope, elevation delta). They live on the
    /// Ignition model — the same values its Site section edits — and they reach
    /// the PIG of every observation this shift freezes, so they belong in front
    /// of the operator at the moment they are asked to confirm the site.
    @Bindable var ignition: IgnitionModel

    /// One-shot GPS. Owned here because the fix is only ever consumed by these
    /// fields; nothing about it is persisted or exported.
    @State private var location = SiteLocationProvider()

    /// Typed coordinate text, committed to the model only when both halves parse
    /// into a real coordinate.
    @State private var latText = ""
    @State private var lonText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.cardSpacing) {
            SectionHeader(title: "Site & radio", annotation: "IMET header")
            siteFactors
            siteGate
            VStack(alignment: .leading, spacing: 10) {
                labeledField("Radio addressee", "e.g. Division W", $model.addressee)
                labeledField("Location name", "e.g. 659 Road", locationNameBinding)
                labeledField("Division", "e.g. Division W", divisionBinding)
                positionHeader
                // Signed, not .numberPad: Badwater Basin is −282 ft and the
                // number pad has no minus key.
                labeledField("Site elevation", "feet MSL", siteElevationBinding,
                             keyboard: .signedNumber)
                HStack(spacing: 10) {
                    labeledField("Latitude", "38.21437", $latText, keyboard: .signedNumber)
                    labeledField("Longitude", "-112.3978", $lonText, keyboard: .signedNumber)
                }
                positionStatus
            }
            .onChange(of: latText) { _, _ in commitCoordinate() }
            .onChange(of: lonText) { _, _ in commitCoordinate() }
        }
        .onAppear { seedCoordinateText() }
        .onChange(of: location.status) { _, status in
            if case .fixed(let fix) = status { apply(fix) }
        }
    }

    // MARK: - Site factors

    /// Aspect, slope, and elevation-vs-weather-site — the IRPG corrections that
    /// every logged observation freezes.
    ///
    /// They sit **above** the gate because the gate's own copy asks the operator
    /// to review the site factors, and until now this screen never showed them:
    /// they were only editable on the Ignition tab while `pendingObs` read them
    /// straight into the record. Placed here rather than in the capture sheet
    /// because they are per-shift site facts, not per-reading measurements — the
    /// sheet stays weather, time, and note.
    private var siteFactors: some View {
        VStack(alignment: .leading, spacing: Metric.cardSpacing) {
            SectionHeader(title: "Site factors", annotation: "Corrections",
                          sharedWith: "Ignition")
            HStack(alignment: .top, spacing: 10) {
                ChipPicker(title: "Aspect", options: Aspect.allCases,
                           selection: $ignition.aspect, label: \.rawValue)
                ChipPicker(title: "Slope", options: Slope.allCases,
                           selection: $ignition.slope, label: \.displayName)
            }
            ChipPicker(title: "Elevation vs. weather site", options: ElevationDelta.allCases,
                       selection: $ignition.elevationDelta, label: \.displayName)
        }
    }

    // MARK: - Site confirmation gate

    /// The once-per-shift site review that gates the first log (red-team #9).
    @ViewBuilder private var siteGate: some View {
        if model.needsSiteConfirmation {
            StatusStrip(icon: "checkmark.shield", message: "Review the site factors, then confirm",
                        caution: true, actionTitle: "Confirm site",
                        action: { model.confirmSite() },
                        identifier: "site-gate", actionIdentifier: "confirm-site")
        } else {
            StatusStrip(icon: "checkmark.shield.fill", message: "Site confirmed for this shift",
                        identifier: "site-confirmed")
        }
    }

    // MARK: - Position: GPS action + provenance

    private var positionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Position").fieldLabel()
            Spacer(minLength: 8)
            Text(provenanceCaption)
                .font(PlateworksFont.labelSmall)
                .foregroundStyle(model.siteSource == .gps ? PlateworksColor.accent : PlateworksColor.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityIdentifier("site-provenance")
            gpsButton
        }
    }

    private var gpsButton: some View {
        Button { location.requestFix() } label: {
            HStack(spacing: 5) {
                if location.isLocating {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "location.fill").font(.system(size: 12, weight: .semibold))
                }
                Text(location.isLocating ? "Locating" : "Use GPS")
                    .font(PlateworksFont.labelSmall).fontWeight(.bold)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: Metric.tapTarget)
            .background(PlateworksColor.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(PlateworksColor.accent, lineWidth: 1.5))
            .foregroundStyle(PlateworksColor.accent)
        }
        .buttonStyle(.plain)
        .disabled(location.isLocating)
        .accessibilityIdentifier("use-gps")
        .accessibilityLabel("Fill site position from GPS")
    }

    /// Where the position on screen came from, so a GPS fill is never mistaken
    /// for a surveyed value.
    private var provenanceCaption: String {
        switch model.siteSource {
        case .gps:
            guard let at = model.siteFixedAt else { return "GPS" }
            return "GPS · \(Self.fixTimeFormatter.string(from: at))"
        case .manual:
            return model.siteCoordinate == nil && model.siteElevationFeet == nil ? "" : "Entered by hand"
        }
    }

    /// One status line for the position: a GPS error, a coordinate the fields
    /// can't commit, or a band-edge caution on a GPS elevation. Band-edge is the
    /// safety-relevant one, so it wins when several could apply.
    @ViewBuilder private var positionStatus: some View {
        if let message = bandEdgeWarning {
            StatusStrip(icon: "exclamationmark.triangle.fill", message: message,
                        caution: true, identifier: "site-band-edge")
        } else if let message = coordinateProblem {
            StatusStrip(icon: "exclamationmark.triangle.fill", message: message,
                        caution: true, identifier: "site-coordinate-problem")
        } else if let message = locationProblem {
            StatusStrip(icon: "location.slash", message: message,
                        caution: true, identifier: "site-location-problem")
        }
    }

    /// A GPS elevation whose uncertainty spans two elevation bands can't pick the
    /// station pressure with confidence — and the station pressure derives the RH
    /// that drives PIG. Say so rather than let the fix be trusted silently.
    private var bandEdgeWarning: String? {
        guard model.siteSource == .gps,
              let fix = location.lastFix,
              fix.straddlesBandBoundary,
              let feet = fix.elevationFeet else { return nil }
        return "GPS elevation \(feet) ft sits on an elevation-band edge (±\(fix.elevationUncertaintyFeet ?? 0) ft) — "
            + "the band sets the station pressure for wet-bulb RH. Confirm against a map."
    }

    private var coordinateProblem: String? {
        guard !(latText.isEmpty && lonText.isEmpty) else { return nil }
        guard let lat = Double(latText.trimmed), let lon = Double(lonText.trimmed) else {
            return "Coordinate incomplete — the last saved position is still in use."
        }
        guard GeoPoint.isValid(latitude: lat, longitude: lon) else {
            return "Coordinate out of range — latitude ±90, longitude ±180. Last saved position still in use."
        }
        return nil
    }

    private var locationProblem: String? {
        switch location.status {
        case .denied:
            return "Location access is off — enable it in Settings, or type the position below."
        case .failed(let reason):
            return reason
        case .idle, .locating, .fixed:
            return nil
        }
    }

    // MARK: - Applying a fix

    private func apply(_ fix: SiteLocationProvider.Fix) {
        model.applySiteFix(coordinate: fix.coordinate,
                           elevationFeet: fix.elevationFeet,
                           at: fix.takenAt)
        // Mirror into the text fields. Assigning these fires commitCoordinate(),
        // which writes back the identical coordinate — the model's manual-edit
        // detection would then flip provenance to .manual, so guard by only
        // committing a coordinate that actually differs (see commitCoordinate).
        //
        // `latitudeText`, not `String(_:)` — the latter spells a fix out to
        // every digit the sensor carried (`38.21437123456789`), which is what
        // these two fields used to show. GeoPoint has already snapped the value
        // to six decimals, so this is that same number, just written the way the
        // exports write it.
        latText = fix.coordinate.latitudeText
        lonText = fix.coordinate.longitudeText
    }

    private func seedCoordinateText() {
        guard let c = model.siteCoordinate else { return }
        latText = c.latitudeText
        lonText = c.longitudeText
    }

    /// Commit typed coordinates, preserving the last good position on partial or
    /// invalid input.
    ///
    /// The previous behavior nil'd `siteCoordinate` whenever *either* field
    /// failed to parse, so clearing longitude to retype one digit silently
    /// discarded the whole sticky position. Now only clearing **both** fields
    /// clears it; anything else in flight leaves the saved coordinate alone and
    /// says so via ``coordinateProblem``.
    private func commitCoordinate() {
        if latText.trimmed.isEmpty && lonText.trimmed.isEmpty {
            if model.siteCoordinate != nil { model.siteCoordinate = nil }
            return
        }
        guard let lat = Double(latText.trimmed), let lon = Double(lonText.trimmed),
              let point = GeoPoint(validating: lat, longitude: lon) else { return }
        // Only write a real change: an identical write would read as a manual
        // edit and drop the GPS provenance we just set.
        if model.siteCoordinate != point { model.siteCoordinate = point }
    }

    // MARK: - Field plumbing

    private var locationNameBinding: Binding<String> {
        Binding(get: { model.shift.locationName ?? "" },
                set: { model.shift.locationName = $0.isEmpty ? nil : $0 })
    }
    private var divisionBinding: Binding<String> {
        Binding(get: { model.shift.division ?? "" },
                set: { model.shift.division = $0.isEmpty ? nil : $0 })
    }
    private var siteElevationBinding: Binding<String> {
        Binding(get: { model.siteElevationFeet.map(String.init) ?? "" },
                set: { text in
                    let t = text.trimmed
                    // Empty clears; anything unparseable leaves the stored value
                    // alone rather than blanking it mid-keystroke.
                    if t.isEmpty { model.siteElevationFeet = nil }
                    else if let v = Int(t) { model.siteElevationFeet = v }
                })
    }

    private func labeledField(_ label: String, _ placeholder: String, _ text: Binding<String>,
                              keyboard: FieldKeyboard = .text) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).fieldLabel()
            TextField(placeholder, text: text)
                .font(PlateworksFont.body)
                .fieldKeyboard(keyboard)
                // The visible label doubles as the identifier so the field is
                // addressable from UI tests and VoiceOver alike.
                .accessibilityIdentifier(label)
                .accessibilityLabel(label)
                .padding(11)
                .frame(minHeight: Metric.tapTarget, alignment: .leading)
                .background(PlateworksColor.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PlateworksColor.hairline))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let fixTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Hmm")
        return f
    }()
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
