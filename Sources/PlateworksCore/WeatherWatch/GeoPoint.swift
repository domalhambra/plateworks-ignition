import Foundation

/// A GPS coordinate attached to an observation, rendered the way the IMET sheet's
/// Location column expects: `"38.214371, -112.397801"` (six decimal places ≈ 0.11 m,
/// trailing zeros trimmed).
///
/// Six decimals is the app's precision everywhere a coordinate is stored, shown,
/// or exported. A raw `CLLocation` carries far more — a fix is a `Double` with
/// fifteen-odd digits, none of which past the sixth mean anything against a
/// consumer GPS's several-metre accuracy — and dumping that into the site
/// editor's text fields is how the operator ended up looking at
/// `38.21437123456789`.
public struct GeoPoint: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Valid ranges for a decimal-degree coordinate.
    public static let latitudeRange: ClosedRange<Double> = -90...90
    public static let longitudeRange: ClosedRange<Double> = -180...180

    /// Whether a decimal-degree pair is a real coordinate. Rejects non-finite
    /// values as well as out-of-range ones, so a `nan` from a parser or a sensor
    /// can't become a location.
    public static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite
            && latitudeRange.contains(latitude)
            && longitudeRange.contains(longitude)
    }

    /// Decimal places kept for a stored coordinate. Six ≈ 0.11 m — an order of
    /// magnitude finer than any consumer GPS fix, and the most a
    /// decimal-degree coordinate is conventionally written with.
    public static let decimals = 6

    /// Snap one component to ``decimals``. Nearest, not floored: truncating
    /// would drag every coordinate systematically south and west.
    ///
    /// Exact for any real coordinate — |value| ≤ 180 keeps `value * 1e6` well
    /// inside the range where `Double` represents integers exactly.
    public static func snapped(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let scale = pow(10.0, Double(decimals))
        return (value * scale).rounded() / scale
    }

    /// Build a coordinate only if the pair is real — the entry point for typed,
    /// parsed, and sensed input alike, so a transposed or half-typed field
    /// (`lat 380.2`) is rejected instead of being frozen onto an observation and
    /// read out on the radio.
    ///
    /// Also where precision is normalized: both components are snapped to
    /// ``decimals``, so the value the model holds, the text the site editor
    /// shows, and the string the exports carry are the same number. Rounding
    /// only on the way out would leave the field showing a value the record
    /// disagreed with in the seventh decimal.
    public init?(validating latitude: Double, longitude: Double) {
        guard Self.isValid(latitude: latitude, longitude: longitude) else { return nil }
        self.init(latitude: Self.snapped(latitude), longitude: Self.snapped(longitude))
    }

    /// `"lat, long"`, e.g. `"38.214371, -112.397801"`.
    public var rendered: String { "\(Self.trim(latitude)), \(Self.trim(longitude))" }

    /// One component on its own, formatted identically to ``rendered`` — so the
    /// site editor's text fields cannot drift from what the exports carry.
    public var latitudeText: String { Self.trim(latitude) }
    public var longitudeText: String { Self.trim(longitude) }

    /// Format to ``decimals`` and trim trailing zeros. `String(format:)` with no
    /// `Locale` uses the C locale, so a comma-decimal device can never emit
    /// `"38,214371"`.
    static func trim(_ value: Double) -> String {
        var s = String(format: "%.\(decimals)f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
