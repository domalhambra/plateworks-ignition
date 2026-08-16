import Foundation
import PlateworksCore

// Emits the cross-implementation conformance vectors for the web port
// (conformance/vectors.json). PlateworksCore is the source of truth: everything
// below is derived through the core's PUBLIC API, so the vectors pin both the
// table data and the lookup/banding math. The Node harness
// (conformance/check-web.js) replays every case against web/engine.js.
//
// Determinism rules: no wall clock, no randomness in any emitted value, UTC
// calendar for anything date-derived, and hand-formatted JSON (one case per
// line) so regenerated diffs are reviewable. Same core ⇒ byte-identical file.
//
// Usage:
//   swift run plateworks-vectors                 # print to stdout
//   swift run plateworks-vectors --out FILE      # write FILE
//   swift run plateworks-vectors --check FILE    # exit 1 if FILE is stale

// MARK: - JSON emission helpers

func jstr(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default:
            if u.value < 0x20 { out += String(format: "\\u%04x", u.value) }
            else { out.unicodeScalars.append(u) }
        }
    }
    return out + "\""
}
func jint(_ v: Int?) -> String { v.map(String.init) ?? "null" }
func jbool(_ v: Bool) -> String { v ? "true" : "false" }
func jrow(_ xs: [Int]) -> String { "[" + xs.map(String.init).joined(separator: ",") + "]" }
func jlines(_ items: [String], indent: String) -> String {
    items.map { indent + $0 }.joined(separator: ",\n")
}

// MARK: - Shared mappings (JSON model ⇄ core model)

let aspects: [Aspect] = [.north, .east, .south, .west]
let slopes: [(String, Slope)] = [("gentle", .gentle), ("steep", .steep)]
let deltas: [(String, ElevationDelta)] = [("below", .below), ("level", .level), ("above", .above)]
let groups: [MonthGroup] = [.tableB, .tableC, .tableD]

func slope(_ s: String) -> Slope { s == "steep" ? .steep : .gentle }
func elevationDelta(_ s: String) -> ElevationDelta {
    s == "below" ? .below : (s == "above" ? .above : .level)
}
func timeOfDay(_ s: String) -> TimeOfDay {
    s == "night" ? .night : TimeOfDay.daytimeBands[Int(s)!]
}
func hhmm(_ min: Int) -> String {
    let h = (min / 60) % 24, m = min % 60
    return String(format: "%02d%02d", h, m)
}

/// The web wind model {low, high, dir, gust} mapped onto the core's optional
/// `Wind`: high ≤ 0 with no gust = not recorded (nil); high ≤ 0 with a gust =
/// light/variable; otherwise a measured speed range. Empty dir = no direction.
struct WindIn {
    let low: Int, high: Int, dir: String, gust: Int
    var core: Wind? {
        let g: Int? = gust > 0 ? gust : nil
        if high <= 0 {
            return g == nil ? nil : Wind.lightVariable(gust: g)
        }
        let direction = dir.isEmpty ? nil : Wind.Direction(rawValue: dir)
        return Wind(speed: .init(low: low, high: high), direction: direction, gust: g)
    }
    /// Always-materialized form for renderings the web computes on the raw
    /// record (spot/spoken/imet treat high ≤ 0 as light/variable).
    var coreForRendering: Wind {
        core ?? Wind.lightVariable(gust: nil)
    }
    var json: String { "{\"low\":\(low),\"high\":\(high),\"dir\":\(jstr(dir)),\"gust\":\(gust)}" }
}

/// Fixed UTC calendar for the date-derived vectors (xlsx sheet names, radio
/// time labels). Namespaced in an enum rather than left as a top-level `var`:
/// under the Swift 6 language mode top-level bindings are main-actor isolated,
/// so the nonisolated section generators below could not reference it. An
/// immutable `Calendar` is `Sendable`, so this is safe from any isolation.
enum UTC {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

func utcDateMs(_ y: Int, _ mo: Int, _ d: Int) -> Int {
    let comps = DateComponents(year: y, month: mo, day: d)
    return Int(UTC.calendar.date(from: comps)!.timeIntervalSince1970) * 1000
}

// MARK: - Observation model used by radio + xlsx cases (the web's logged-obs shape)

struct ObsIn {
    let min: Int
    let temp: Int
    let rh: Int
    let month: Int
    let timeBand: String
    let aspect: Aspect
    let slopeKey: String
    let deltaKey: String
    let wind: WindIn
    let elevationFeet: Int?
    let spokenLocation: String
    let note: String?

    var estimate: IgnitionEstimate {
        IgnitionCalculator.estimate(IgnitionInput(
            dryBulbF: temp, relativeHumidity: rh, month: month,
            timeOfDay: timeOfDay(timeBand), aspect: aspect,
            slope: slope(slopeKey), elevationDelta: elevationDelta(deltaKey)))
    }

    func weatherObs(dayMs: Int, location: GeoPoint?) -> WeatherObs {
        WeatherObs(
            timestamp: Date(timeIntervalSince1970: Double(dayMs) / 1000 + Double(min * 60)),
            estimate: estimate,
            humidity: nil,
            rhSource: .direct,
            note: note,
            wind: wind.core,
            elevationFeet: elevationFeet,
            location: location,
            spokenLocation: spokenLocation.isEmpty ? nil : spokenLocation)
    }

    var json: String {
        let e = estimate
        return "{\"min\":\(min),\"temp\":\(temp),\"rh\":\(rh),\"month\":\(month),"
            + "\"timeBand\":\(jstr(timeBand)),\"aspect\":\(jstr(aspect.rawValue)),"
            + "\"slope\":\(jstr(slopeKey)),\"elevationDelta\":\(jstr(deltaKey)),"
            + "\"wind\":\(wind.json),\"elevationFeet\":\(jint(elevationFeet)),"
            + "\"spokenLocation\":\(jstr(spokenLocation)),\"note\":\(note.map(jstr) ?? "null"),"
            + "\"pigU\":\(e.unshaded.probabilityOfIgnition),\"pigS\":\(e.shaded.probabilityOfIgnition)}"
    }
}

// MARK: - Sections

func tablesSection() -> String {
    // Table A reconstructed through the public lookup: representative temp per
    // row band, RH per 5% column (col 20 = 100%).
    let refTemps = [10, 30, 50, 70, 90, 110]
    let refGrid = refTemps.map { t in
        (0...20).map { col in
            ReferenceFuelMoistureTable.referenceFuelMoisture(dryBulbF: t, relativeHumidity: col == 20 ? 100 : col * 5)
        }
    }
    // Tables B/C/D via the public correction lookup. Unshaded rows: aspect ×
    // slope (N/g, N/s, E/g, …); shaded rows: aspect. Columns: time band × B/L/A.
    func corrGrid(_ g: MonthGroup, shaded: Bool) -> [[Int]] {
        var rows: [[Int]] = []
        for a in aspects {
            for (_, s) in (shaded ? [("gentle", Slope.gentle)] : slopes) {
                var row: [Int] = []
                for band in TimeOfDay.daytimeBands {
                    for (_, d) in deltas {
                        row.append(FuelMoistureCorrectionTable.correction(
                            monthGroup: g, shading: shaded ? .shaded : .unshaded,
                            aspect: a, slope: s, timeOfDay: band, elevationDelta: d)!)
                    }
                }
                rows.append(row)
            }
        }
        return rows
    }
    // PIG grids via the public lookup: rows 110+ … 30-39, columns FFM 2…17.
    let pigTemps = [110, 100, 90, 80, 70, 60, 50, 40, 30]
    func pigGrid(_ shading: Shading) -> [[Int]] {
        pigTemps.map { t in
            (2...17).map { ProbabilityOfIgnitionTable.probabilityOfIgnition(dryBulbF: t, fineFuelMoisture: $0, shading: shading) }
        }
    }
    func grid(_ g: [[Int]], indent: String) -> String {
        "[\n" + jlines(g.map(jrow), indent: indent + " ") + "\n" + indent + "]"
    }
    func corrPair(_ g: MonthGroup) -> String {
        "{\n   \"u\": \(grid(corrGrid(g, shaded: false), indent: "   ")),\n   \"s\": \(grid(corrGrid(g, shaded: true), indent: "   "))\n  }"
    }
    return """
"tables": {
 "refGrid": \(grid(refGrid, indent: " ")),
 "corr": {
  "B": \(corrPair(.tableB)),
  "C": \(corrPair(.tableC)),
  "D": \(corrPair(.tableD))
 },
 "pigU": \(grid(pigGrid(.unshaded), indent: " ")),
 "pigS": \(grid(pigGrid(.shaded), indent: " "))
}
"""
}

func rfmCases() -> String {
    let temps = [9, 10, 29, 30, 49, 50, 69, 70, 89, 90, 109, 110, 111, 130]
    let rhs = [0, 4, 5, 9, 10, 25, 49, 50, 74, 75, 99, 100]
    var rows: [String] = []
    for t in temps {
        for rh in rhs {
            rows.append(jrow([t, rh, ReferenceFuelMoistureTable.referenceFuelMoisture(dryBulbF: t, relativeHumidity: rh)]))
        }
    }
    return "\"rfmCases\": [\n" + jlines(rows, indent: " ") + "\n]"
}

func corrCases() -> String {
    var rows: [String] = []
    for g in groups {
        for shaded in [false, true] {
            for a in aspects {
                for (sk, s) in (shaded ? [slopes[0]] : slopes) {
                    for bandIdx in [0, 2, 5] {
                        for (dk, d) in deltas {
                            let c = FuelMoistureCorrectionTable.correction(
                                monthGroup: g, shading: shaded ? .shaded : .unshaded,
                                aspect: a, slope: s, timeOfDay: TimeOfDay.daytimeBands[bandIdx],
                                elevationDelta: d)!
                            rows.append("[\(jstr(g.letter)),\(jstr(shaded ? "s" : "u")),\(jstr(a.rawValue)),\(jstr(sk)),\(bandIdx),\(jstr(dk)),\(c)]")
                        }
                    }
                }
            }
        }
    }
    return "\"corrCases\": [\n" + jlines(rows, indent: " ") + "\n]"
}

func pigCases() -> String {
    let temps = [20, 29, 30, 39, 40, 59, 69, 79, 89, 99, 109, 110, 125]
    let ffms = [0, 1, 2, 5, 9, 16, 17, 18, 25]
    var rows: [String] = []
    for t in temps {
        for f in ffms {
            for shaded in [false, true] {
                let p = ProbabilityOfIgnitionTable.probabilityOfIgnition(
                    dryBulbF: t, fineFuelMoisture: f, shading: shaded ? .shaded : .unshaded)
                rows.append("[\(t),\(f),\(jstr(shaded ? "s" : "u")),\(p)]")
            }
        }
    }
    return "\"pigCases\": [\n" + jlines(rows, indent: " ") + "\n]"
}

func behaviorSection() -> String {
    let entries = FireBehavior.allCases.map {
        "{\"t\":\(jstr($0.title)),\"r\":\(jstr($0.pigRangeLabel)),\"d\":\(jstr($0.detail))}"
    }
    let pigs = [0, 5, 9, 10, 15, 19, 20, 25, 29, 30, 40, 49, 50, 60, 70, 75, 79, 80, 90, 100]
    let cases = pigs.map { jrow([$0, FireBehaviorInterpretation.interpretation(forPIG: $0).rawValue]) }
    return """
"behaviorTable": [
\(jlines(entries, indent: " "))
],
"caution": \(jstr(FireBehaviorInterpretation.caution)),
"behaviorCases": [
\(jlines(cases, indent: " "))
]
"""
}

func monthGroupCases() -> String {
    let rows = (1...12).map { "[\($0),\(jstr(MonthGroup.from(month: $0).letter))]" }
    return "\"monthGroupCases\": [\n" + jlines(rows, indent: " ") + "\n]"
}

func timeBandCases() -> String {
    let clocks = [(0, 0), (5, 30), (7, 59), (8, 0), (9, 59), (10, 0), (11, 59), (12, 0),
                  (13, 59), (14, 0), (15, 59), (16, 0), (17, 59), (18, 0), (19, 59), (20, 0), (23, 59)]
    let rows = clocks.map { (h, m) -> String in
        let t = TimeOfDay.from(hour: h, minute: m)
        let v = t.isNight ? "night" : String(t.correctionColumnIndex!)
        return "[\(h),\(m),\(jstr(v))]"
    }
    return "\"timeBandCases\": [\n" + jlines(rows, indent: " ") + "\n]"
}

func psychroCases() -> String {
    var rows: [String] = []
    var inputs: [(Int, Int, Int)] = []
    for dry in [40, 50, 60, 70, 75, 80, 90, 100, 110] {
        for off in [-25, -15, -8, -4, -2, -1, 0] {
            for band in [1, 3, 4, 6] {
                inputs.append((dry, max(10, dry + off), band))
            }
        }
    }
    inputs.append((70, 75, 3))   // wet > dry clamps to saturation
    inputs.append((33, 32, 1))   // cold, near-freezing
    for (dry, wet, band) in inputs {
        let r = Psychrometrics.compute(dryBulbF: dry, wetBulbF: wet, band: ElevationBand(rawValue: band)!)
        rows.append(jrow([dry, wet, band, r.relativeHumidity, r.dewPointF, r.wetBulbDepressionF]))
    }
    return "\"psychroCases\": [\n" + jlines(rows, indent: " ") + "\n]"
}

func elevationBandCases() -> String {
    var rows: [String] = []
    for feet in [-282, 0, 500, 501, 1900, 1901, 3900, 3901, 6100, 6101, 8500, 8501, 12000] {
        rows.append(jrow([feet, 0, ElevationBand.forElevation(feetMSL: feet, alaska: false).rawValue]))
    }
    for feet in [-10, 300, 301, 1700, 1701, 3600, 3601, 5700, 5701, 7900, 7901, 9000] {
        rows.append(jrow([feet, 1, ElevationBand.forElevation(feetMSL: feet, alaska: true).rawValue]))
    }
    return "\"elevationBandCases\": [\n" + jlines(rows, indent: " ") + "\n]"
}

// Chain case row: [dryBulbF, rh, month, timeBand, aspect, slope, delta,
//                  rf, night, corrU, corrS, ffmU, ffmS, pigU, pigS, behU, behS]
func chainCases() -> String {
    let temps = [25, 35, 55, 75, 95, 115]
    let rhs = [3, 7, 12, 26, 49, 50, 74, 95, 100]
    let months = [1, 3, 5, 7, 9, 11]
    let bands = ["0", "2", "5", "night"]
    var rows: [String] = []
    var i = 0
    var combos: [(Int, Int, Int, String, Aspect, String, String)] = []
    for t in temps {
        for rh in rhs {
            combos.append((t, rh, months[i % 6], bands[i % 4], aspects[i % 4],
                           slopes[i % 2].0, deltas[i % 3].0))
            i += 1
        }
    }
    combos.append((90, 8, 12, "night", .south, "steep", "level"))   // winter night
    combos.append((60, 100, 2, "0", .north, "gentle", "below"))     // RH clamp top
    combos.append((9, 0, 6, "3", .west, "steep", "above"))          // temp clamp low
    for (t, rh, month, band, a, sk, dk) in combos {
        let e = IgnitionCalculator.estimate(IgnitionInput(
            dryBulbF: t, relativeHumidity: rh, month: month, timeOfDay: timeOfDay(band),
            aspect: a, slope: slope(sk), elevationDelta: elevationDelta(dk)))
        let behU = FireBehaviorInterpretation.interpretation(forPIG: e.unshaded.probabilityOfIgnition).rawValue
        let behS = FireBehaviorInterpretation.interpretation(forPIG: e.shaded.probabilityOfIgnition).rawValue
        rows.append("[\(t),\(rh),\(month),\(jstr(band)),\(jstr(a.rawValue)),\(jstr(sk)),\(jstr(dk)),"
            + "\(e.referenceFuelMoisture),\(jbool(e.isNight)),\(jint(e.unshaded.correction)),\(jint(e.shaded.correction)),"
            + "\(e.unshaded.fineFuelMoisture),\(e.shaded.fineFuelMoisture),"
            + "\(e.unshaded.probabilityOfIgnition),\(e.shaded.probabilityOfIgnition),\(behU),\(behS)]")
    }
    return "\"chainCases\": [\n" + jlines(rows, indent: " ") + "\n]"
}

// Wind case row: [low, high, dir, gust, spot, spoken, imet]
func windCases() -> String {
    let winds: [WindIn] = [
        WindIn(low: 3, high: 6, dir: "SW", gust: 0),
        WindIn(low: 3, high: 6, dir: "SW", gust: 12),
        WindIn(low: 0, high: 0, dir: "", gust: 0),
        WindIn(low: 0, high: 0, dir: "", gust: 12),
        WindIn(low: 8, high: 8, dir: "N", gust: 0),
        WindIn(low: 1, high: 1, dir: "W", gust: 0),
        WindIn(low: 4, high: 6, dir: "", gust: 0),
        WindIn(low: 1, high: 3, dir: "W", gust: 18),
        WindIn(low: 0, high: 5, dir: "E", gust: 0),
        WindIn(low: 5, high: 5, dir: "NE", gust: 25),
    ]
    let rows = winds.map { w -> String in
        let r = w.coreForRendering
        return "[\(w.low),\(w.high),\(jstr(w.dir)),\(w.gust),\(jstr(r.spotString)),\(jstr(r.spokenPhrase)),\(jstr(r.imetCell))]"
    }
    return "\"windCases\": [\n" + jlines(rows, indent: " ") + "\n]"
}

func crcCases() -> String {
    let texts = ["", "a", "abc", "123456789",
                 "The quick brown fox jumps over the lazy dog",
                 "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"/>"]
    let rows = texts.map { "[\(jstr($0)),\(CRC32.checksum(Array($0.utf8)))]" }
    return "\"crc32Cases\": [\n" + jlines(rows, indent: " ") + "\n]"
}

func radioCases() -> String {
    let siteWind = WindIn(low: 1, high: 3, dir: "W", gust: 0)
    let noWind = WindIn(low: 0, high: 0, dir: "", gust: 0)
    func obs(_ min: Int, _ temp: Int, _ rh: Int, wind: WindIn = WindIn(low: 3, high: 6, dir: "SW", gust: 0),
             aspect: Aspect = .west, slopeKey: String = "steep", elevationFeet: Int? = 10300,
             spokenLocation: String = "near the 659 road") -> ObsIn {
        ObsIn(min: min, temp: temp, rh: rh, month: 7, timeBand: "2", aspect: aspect,
              slopeKey: slopeKey, deltaKey: "level", wind: wind, elevationFeet: elevationFeet,
              spokenLocation: spokenLocation, note: nil)
    }
    // (name, addressee, cur, prev)
    let cases: [(String, String, ObsIn, ObsIn?)] = [
        ("first-obs-full-site", "Diamond Mountain",
         obs(540, 60, 25, wind: siteWind), nil),
        ("same-site-no-wind", "Diamond Mountain",
         obs(600, 65, 22, wind: noWind), obs(540, 60, 25, wind: siteWind)),
        ("same-site-measured-wind", "Diamond Mountain",
         obs(600, 65, 20), obs(540, 60, 25)),
        ("elevation-changed", "Diamond Mountain",
         obs(660, 70, 18, elevationFeet: 9800), obs(600, 65, 20)),
        ("aspect-changed-east-gentle", "Ops",
         obs(720, 72, 16, aspect: .east, slopeKey: "gentle"), obs(660, 70, 18)),
        ("no-addressee-no-site", "",
         obs(780, 74, 15, elevationFeet: nil, spokenLocation: ""), nil),
        ("light-variable-gust", "Diamond Mountain",
         obs(840, 76, 14, wind: WindIn(low: 0, high: 0, dir: "", gust: 12)), obs(780, 74, 15)),
        ("no-change-deltas", "Diamond Mountain",
         obs(900, 76, 14), obs(840, 76, 14)),
        ("location-text-changed", "Diamond Mountain",
         obs(960, 78, 13, spokenLocation: "at the saddle"), obs(900, 78, 13)),
        ("steep-east-article", "Weather",
         obs(1020, 80, 12, aspect: .east, slopeKey: "steep"), nil),
        ("single-mph-wind", "Diamond Mountain",
         obs(1080, 81, 12, wind: WindIn(low: 1, high: 1, dir: "N", gust: 0)), obs(1020, 80, 12)),
    ]
    let rows = cases.map { (name, addressee, cur, prev) -> String in
        let expect = RadioScript.render(
            addressee: addressee,
            timeLabel: hhmm(cur.min),
            spokenLocation: cur.spokenLocation.isEmpty ? nil : cur.spokenLocation,
            current: cur.weatherObs(dayMs: utcDateMs(2026, 7, 6), location: nil),
            previous: prev.map { $0.weatherObs(dayMs: utcDateMs(2026, 7, 6), location: nil) })
        return "{\"name\":\(jstr(name)),\"addressee\":\(jstr(addressee)),\"cur\":\(cur.json),"
            + "\"prev\":\(prev.map { $0.json } ?? "null"),\"expect\":\(jstr(expect))}"
    }
    return "\"radioCases\": [\n" + jlines(rows, indent: " ") + "\n]"
}

func xlsxCases() -> String {
    struct ShiftIn {
        let dateMs: Int
        let division: String
        let locationName: String
        let obs: [ObsIn]
        func json() -> String {
            "{\"dateMs\":\(dateMs),\"division\":\(jstr(division)),\"locationName\":\(jstr(locationName)),\"obs\":["
                + obs.map { $0.json }.joined(separator: ",") + "]}"
        }
        func core(location: GeoPoint?) -> Shift {
            Shift(started: Date(timeIntervalSince1970: Double(dateMs) / 1000),
                  obs: obs.map { $0.weatherObs(dayMs: dateMs, location: location) },
                  division: division.isEmpty ? nil : division,
                  locationName: locationName.isEmpty ? nil : locationName)
        }
    }
    func windless() -> WindIn { WindIn(low: 0, high: 0, dir: "", gust: 0) }
    let day1 = ShiftIn(
        dateMs: utcDateMs(2026, 7, 6), division: "Division W", locationName: "659 Road",
        obs: [
            ObsIn(min: 540, temp: 88, rh: 12, month: 7, timeBand: "0", aspect: .south, slopeKey: "steep",
                  deltaKey: "level", wind: WindIn(low: 3, high: 6, dir: "SW", gust: 0),
                  elevationFeet: 4150, spokenLocation: "near the 659 road", note: nil),
            ObsIn(min: 600, temp: 92, rh: 10, month: 7, timeBand: "1", aspect: .south, slopeKey: "steep",
                  deltaKey: "level", wind: windless(),
                  elevationFeet: 4150, spokenLocation: "near the 659 road", note: "sun on thermometer"),
            ObsIn(min: 690, temp: 95, rh: 8, month: 7, timeBand: "1", aspect: .south, slopeKey: "steep",
                  deltaKey: "level", wind: WindIn(low: 0, high: 0, dir: "", gust: 14),
                  elevationFeet: 4150, spokenLocation: "near the 659 road", note: nil),
        ])
    let day2 = ShiftIn(
        dateMs: utcDateMs(2026, 7, 7), division: "Division W", locationName: "659 Road",
        obs: [
            ObsIn(min: 555, temp: 84, rh: 16, month: 7, timeBand: "0", aspect: .south, slopeKey: "steep",
                  deltaKey: "level", wind: WindIn(low: 5, high: 5, dir: "NE", gust: 25),
                  elevationFeet: nil, spokenLocation: "near the 659 road", note: nil),
        ])
    let day2b = ShiftIn(
        dateMs: utcDateMs(2026, 7, 7), division: "Division W", locationName: "Spur 12",
        obs: [
            ObsIn(min: 900, temp: 97, rh: 7, month: 7, timeBand: "3", aspect: .west, slopeKey: "gentle",
                  deltaKey: "above", wind: WindIn(low: 8, high: 12, dir: "W", gust: 0),
                  elevationFeet: 5200, spokenLocation: "on spur 12", note: nil),
        ])
    let empty = ShiftIn(dateMs: utcDateMs(2026, 8, 1), division: "", locationName: "Spring Gulch", obs: [])

    // (name, shifts, coordLat, coordLon) — coords chosen so the web's raw
    // "lat, lon" string equals GeoPoint.rendered (≤6 dp, no trailing zeros).
    // The web has no GeoPoint: app.js passes the typed lat/lon text straight
    // through, so a case with more decimals than the core keeps would fail the
    // xlsx byte-comparison for a formatting reason rather than a real one.
    let cases: [(String, [ShiftIn], String, String)] = [
        ("single-day-coords", [day1], "38.214", "-112.398"),
        ("multi-day-duplicate-tab", [day1, day2, day2b], "", ""),
        ("empty-book", [empty], "", ""),
    ]
    let rows = cases.map { (name, shifts, lat, lon) -> String in
        let location: GeoPoint? = (lat.isEmpty || lon.isEmpty) ? nil : GeoPoint(latitude: Double(lat)!, longitude: Double(lon)!)
        let data = IMETWorkbook.build(from: shifts.map { $0.core(location: location) }, calendar: UTC.calendar)
        return "{\"name\":\(jstr(name)),\"coordLat\":\(jstr(lat)),\"coordLon\":\(jstr(lon)),\"shifts\":["
            + shifts.map { $0.json() }.joined(separator: ",")
            + "],\"b64\":\(jstr(data.base64EncodedString()))}"
    }
    return "\"xlsxCases\": [\n" + jlines(rows, indent: " ") + "\n]"
}

// Known divergence: web/app.js `edge()` approximates this with a 4-corner probe
// and a ±3 °F wet-bulb step. Vectors are emitted now so the port can flip the
// harness's skip into an assertion when it lands. See docs/PARITY.md.
func sensitivityCases() -> String {
    struct SIn {
        let dry: Int; let source: RHSource; let rh: Int; let wet: Int; let band: Int
        let month: Int; let timeBand: String; let aspect: Aspect; let slopeKey: String; let deltaKey: String
    }
    let cases: [SIn] = [
        SIn(dry: 89, source: .direct, rh: 24, wet: 0, band: 4, month: 7, timeBand: "2", aspect: .south, slopeKey: "steep", deltaKey: "level"),
        SIn(dry: 95, source: .direct, rh: 12, wet: 0, band: 4, month: 7, timeBand: "2", aspect: .south, slopeKey: "steep", deltaKey: "level"),
        SIn(dry: 60, source: .direct, rh: 50, wet: 0, band: 2, month: 4, timeBand: "0", aspect: .north, slopeKey: "gentle", deltaKey: "below"),
        SIn(dry: 78, source: .wetBulb, rh: 0, wet: 60, band: 4, month: 6, timeBand: "3", aspect: .west, slopeKey: "steep", deltaKey: "level"),
        SIn(dry: 70, source: .wetBulb, rh: 0, wet: 68, band: 1, month: 9, timeBand: "5", aspect: .east, slopeKey: "gentle", deltaKey: "above"),
        SIn(dry: 105, source: .direct, rh: 5, wet: 0, band: 6, month: 8, timeBand: "night", aspect: .south, slopeKey: "steep", deltaKey: "level"),
    ]
    func envelope(_ e: Sensitivity.Envelope) -> String {
        let notable = e.notable.map {
            "{\"dryBulbF\":\($0.dryBulbF),\"relativeHumidity\":\($0.relativeHumidity),\"pig\":\($0.pig),"
                + "\"dryBulbShifted\":\(jbool($0.dryBulbShifted)),\"humidityShifted\":\(jbool($0.humidityShifted))}"
        } ?? "null"
        return "{\"baseline\":\(e.baseline),\"pigLow\":\(e.pigLow),\"pigHigh\":\(e.pigHigh),\"notable\":\(notable)}"
    }
    let rows = cases.map { c -> String in
        let s = SensitivityAnalysis.analyze(
            dryBulbF: c.dry, rhSource: c.source, relativeHumidity: c.rh, wetBulbF: c.wet,
            band: ElevationBand(rawValue: c.band)!, month: c.month, timeOfDay: timeOfDay(c.timeBand),
            aspect: c.aspect, slope: slope(c.slopeKey), elevationDelta: elevationDelta(c.deltaKey))
        return "{\"in\":{\"dryBulbF\":\(c.dry),\"rhSource\":\(jstr(c.source == .direct ? "direct" : "wetBulb")),"
            + "\"relativeHumidity\":\(c.rh),\"wetBulbF\":\(c.wet),\"band\":\(c.band),\"month\":\(c.month),"
            + "\"timeBand\":\(jstr(c.timeBand)),\"aspect\":\(jstr(c.aspect.rawValue)),\"slope\":\(jstr(c.slopeKey)),"
            + "\"elevationDelta\":\(jstr(c.deltaKey))},"
            + "\"out\":{\"unshaded\":\(envelope(s.unshaded)),\"shaded\":\(envelope(s.shaded)),"
            + "\"summary\":\(jstr(s.toleranceSummary))}}"
    }
    return "\"sensitivityCases\": [\n" + jlines(rows, indent: " ") + "\n]"
}

// MARK: - Assemble

func generate() -> String {
    let meta = """
"meta": {
 "version": 1,
 "source": "Sources/PlateworksCore (IRPG PMS 461 / PMS 437)",
 "generatedBy": "swift run plateworks-vectors --out conformance/vectors.json",
 "tz": "Date-derived cases (xlsx sheet names/titles) assume TZ=UTC on both sides",
 "chainCaseColumns": ["dryBulbF","rh","month","timeBand","aspect","slope","elevationDelta","rf","night","corrU","corrS","ffmU","ffmS","pigU","pigS","behU","behS"],
 "windCaseColumns": ["low","high","dir","gust","spot","spoken","imet"],
 "psychroCaseColumns": ["dryBulbF","wetBulbF","band","rh","dewPointF","depressionF"]
}
"""
    let sections = [
        meta,
        tablesSection(),
        rfmCases(),
        corrCases(),
        pigCases(),
        behaviorSection(),
        monthGroupCases(),
        timeBandCases(),
        psychroCases(),
        elevationBandCases(),
        chainCases(),
        windCases(),
        crcCases(),
        radioCases(),
        xlsxCases(),
        sensitivityCases(),
    ]
    return "{\n" + sections.joined(separator: ",\n") + "\n}\n"
}

// MARK: - CLI

let args = CommandLine.arguments
let output = generate()

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
    let path = args[i + 1]
    do {
        try output.write(toFile: path, atomically: true, encoding: .utf8)
        print("wrote \(path) (\(output.utf8.count) bytes)")
    } catch {
        fail("cannot write \(path): \(error)")
    }
} else if let i = args.firstIndex(of: "--check"), i + 1 < args.count {
    let path = args[i + 1]
    guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("STALE VECTORS: \(path) is missing. Run: swift run plateworks-vectors --out \(path)")
    }
    if existing == output {
        print("vectors up to date: \(path)")
    } else {
        let a = existing.split(separator: "\n", omittingEmptySubsequences: false)
        let b = output.split(separator: "\n", omittingEmptySubsequences: false)
        var line = 0
        while line < min(a.count, b.count) && a[line] == b[line] { line += 1 }
        let have = line < a.count ? String(a[line].prefix(120)) : "<eof>"
        let want = line < b.count ? String(b[line].prefix(120)) : "<eof>"
        fail("""
        STALE VECTORS: \(path) no longer matches PlateworksCore (first diff at line \(line + 1)).
          committed: \(have)
          expected:  \(want)
        The core changed without regenerating the conformance vectors.
        Run: swift run plateworks-vectors --out \(path)  — then bring web/engine.js to parity
        (CI's web-conformance job will hold the line until it matches).
        """)
    }
} else {
    print(output, terminator: "")
}
