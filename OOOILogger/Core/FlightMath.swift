import Foundation

// Port of the add-on's core.js (and flightmath.py). Keep the two in step.

let RAD = Double.pi / 180

struct LatLon: Equatable { var lat: Double; var lon: Double }

struct Airport {
    let lat: Double
    let lon: Double
    let tzName: String
    var p: LatLon { LatLon(lat: lat, lon: lon) }
}

/// The airport list (AP_TZ + AP_RAW from airports.js). Starts from the copy in the app and is
/// replaced by Home Assistant's copy when the add-on's database has been updated.
final class Airports {
    static let shared = Airports()
    private(set) var ap: [String: Airport] = [:]
    private(set) var count = 0
    private let lock = NSLock()

    /// Airports whose ICAO code changed; old logbooks still use the old code.
    static let formerICAO = ["KPBI": "KDJT"]

    @discardableResult
    func load(js: String) -> Bool {
        guard let parsed = Airports.parse(js), parsed.count > 100 else { return false }
        var m = parsed
        for (old, cur) in Airports.formerICAO where m[old] == nil { if let a = m[cur] { m[old] = a } }
        lock.lock(); ap = m; count = parsed.count; lock.unlock()
        return true
    }

    static func parse(_ src: String) -> [String: Airport]? {
        guard let tzStart = src.range(of: "const AP_TZ="), let tzEnd = src.range(of: "];", range: tzStart.upperBound..<src.endIndex),
              let rawStart = src.range(of: "const AP_RAW=\""), let rawEnd = src.range(of: "\"", range: rawStart.upperBound..<src.endIndex)
        else { return nil }
        let tzJSON = String(src[tzStart.upperBound..<tzEnd.lowerBound]) + "]"
        guard let tzs = try? JSONDecoder().decode([String].self, from: Data(tzJSON.utf8)) else { return nil }
        var out: [String: Airport] = [:]
        out.reserveCapacity(12000)
        for e in src[rawStart.upperBound..<rawEnd.lowerBound].split(separator: ";") {
            guard e.count > 4 else { continue }
            let code = String(e.prefix(4))
            let parts = e.dropFirst(4).split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 3, let lat = Double(parts[0]), let lon = Double(parts[1]), let tz = Int(parts[2]), tz >= 0, tz < tzs.count else { continue }
            out[code] = Airport(lat: lat, lon: lon, tzName: tzs[tz])
        }
        return out
    }

    subscript(_ code: String) -> Airport? {
        lock.lock(); defer { lock.unlock() }
        return ap[code]
    }
}

var AP: Airports { Airports.shared }

func apCode(_ c: String) -> String {
    if let cur = Airports.formerICAO[c], AP[cur] != nil { return cur }
    return c
}

func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

func sunAlt(_ ms: Double, _ lat: Double, _ lon: Double) -> Double {
    let n = ms / 86400000 + 2440587.5 - 2451545.0
    let L = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
    let g = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360) * RAD
    let lam = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)) * RAD
    let eps = (23.439 - 0.0000004 * n) * RAD
    let ra = atan2(cos(eps) * sin(lam), cos(lam))
    let dec = asin(sin(eps) * sin(lam))
    let gmst = (280.46061837 + 360.98564736629 * n).truncatingRemainder(dividingBy: 360)
    let H = (gmst + lon) * RAD - ra
    return asin(sin(lat * RAD) * sin(dec) + cos(lat * RAD) * cos(dec) * cos(H)) / RAD
}

func gcPoint(_ a: LatLon, _ b: LatLon, _ f: Double) -> LatLon {
    let la1 = a.lat * RAD, lo1 = a.lon * RAD, la2 = b.lat * RAD, lo2 = b.lon * RAD
    let s1 = sin((la2 - la1) / 2), s2 = sin((lo2 - lo1) / 2)
    let d = 2 * asin(sqrt(s1 * s1 + cos(la1) * cos(la2) * s2 * s2))
    if d < 1e-9 { return a }
    let A = sin((1 - f) * d) / sin(d), B = sin(f * d) / sin(d)
    let x = A * cos(la1) * cos(lo1) + B * cos(la2) * cos(lo2)
    let y = A * cos(la1) * sin(lo1) + B * cos(la2) * sin(lo2)
    let z = A * sin(la1) + B * sin(la2)
    return LatLon(lat: atan2(z, hypot(x, y)) / RAD, lon: atan2(y, x) / RAD)
}

func distNm(_ a: LatLon, _ b: LatLon) -> Double {
    let la1 = a.lat * RAD, la2 = b.lat * RAD, dl = (b.lon - a.lon) * RAD
    let s1 = sin((la2 - la1) / 2), s2 = sin(dl / 2)
    let d = 2 * asin(sqrt(s1 * s1 + cos(la1) * cos(la2) * s2 * s2))
    return d * 3440.065
}

struct Times {
    var out: Double
    var off: Double?
    var on: Double?
    var inT: Double?
    var crew: Double?
}

/// Night = sun below −6°, sampled each minute from OUT to IN. The aircraft sits at the origin until OFF,
/// moves along the great circle OFF→ON, then sits at the destination until IN.
func nightMinutes(_ t: Times, _ a: LatLon, _ b: LatLon) -> Int {
    guard let off = t.off, let on = t.on, let inT = t.inT else { return 0 }
    var n = 0
    let span = on - off
    var s = t.out
    while s < inT {
        let m = s + 30000
        let f = span > 0 ? min(max((m - off) / span, 0), 1) : 0
        let p = gcPoint(a, b, f)
        if sunAlt(m, p.lat, p.lon) < -6 { n += 1 }
        s += 60000
    }
    return n
}

/// FAA 61.57(b): 1 hr after sunset to 1 hr before sunrise.
func isNightOp(_ ms: Double, _ ap: LatLon) -> Bool {
    let H = 3600000.0
    return sunAlt(ms - H, ap.lat, ap.lon) < -0.833 && sunAlt(ms + H, ap.lat, ap.lon) < -0.833
}

private var calCache: [String: Calendar] = [:]
private let calLock = NSLock()
private func calendar(_ tz: String) -> Calendar {
    calLock.lock(); defer { calLock.unlock() }
    if let c = calCache[tz] { return c }
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz) ?? TimeZone(identifier: "UTC")!
    calCache[tz] = c
    return c
}

/// Local calendar date (YYYY-MM-DD) of a UTC instant in an IANA zone.
func localDate(_ ms: Double, _ tz: String) -> String {
    let c = calendar(tz).dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ms / 1000))
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

func hhmm(_ v: String?) -> Int? {
    let s = (v ?? "").filter { $0.isASCII && $0.isNumber }
    guard s.count >= 3, s.count <= 4 else { return nil }
    let p = String(repeating: "0", count: 4 - s.count) + s
    guard let h = Int(p.prefix(2)), let m = Int(p.suffix(2)) else { return nil }
    return h < 24 && m < 60 ? h * 60 + m : nil
}

/// Midnight UTC of a YYYY-MM-DD date, in ms.
func isoDayMs(_ iso: String) -> Double? {
    let p = iso.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3 else { return nil }
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
    guard let d = c.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return nil }
    return d.timeIntervalSince1970 * 1000
}

/// Turn the logged date (local date at the departure airport) + HHMM UTC strings into instants.
func resolveTimes(_ f: Flight) -> Times? {
    guard !f.date.isEmpty, let out = hhmm(f.out), let base = isoDayMs(f.date) else { return nil }
    var outMs = base + Double(out) * 60000
    if let dep = AP[f.from] {
        // pick the UTC day whose local date at the origin matches the logged date
        for d in [0.0, 1, -1] {
            let c = base + d * 86400000 + Double(out) * 60000
            if localDate(c, dep.tzName) == f.date { outMs = c; break }
        }
    }
    func after(_ prev: Double?, _ v: Int?) -> Double? {
        guard let prev, let v else { return nil }
        var c = prev - prev.truncatingRemainder(dividingBy: 86400000) + Double(v) * 60000
        while c < prev { c += 86400000 }
        return c
    }
    var t = Times(out: outMs)
    t.off = after(t.out, hhmm(f.off))
    t.on = t.off != nil ? after(t.off, hhmm(f.on)) : nil
    t.inT = after(t.on ?? t.off ?? t.out, hhmm(f.inTime))
    if let crew = hhmm(f.crew) {
        var c = t.out - t.out.truncatingRemainder(dividingBy: 86400000) + Double(crew) * 60000
        while c > t.out { c -= 86400000 }
        t.crew = c
    }
    return t
}

func hrs(_ min: Int) -> Double { jsRound(Double(min) / 60 * 100) / 100 }

struct Calc {
    var ok = false
    var t: Times?
    var missing: [String] = []
    var totalMin = 0, blockMin = 0, airMin = 0
    var total = 0.0, night = 0.0
    var nightMin = 0
    var nightTO = false, nightLdg = false
    var distNm = 0
    var landings = 0, fsNight = 0, fsDay = 0, takeoffs = 0, nightTakeoffs = 0
}

func compute(_ f: Flight) -> Calc {
    let t = resolveTimes(f)
    let a = AP[f.from], b = AP[f.to]
    var r = Calc(t: t)
    if a == nil { r.missing.append("departure airport") }
    if b == nil { r.missing.append("arrival airport") }
    if t == nil || t?.off == nil || t?.on == nil || t?.inT == nil { r.missing.append("OOOI times") }
    guard r.missing.isEmpty, let t, let a, let b, let off = t.off, let on = t.on, let inT = t.inT else { return r }
    let startMs = t.crew ?? t.out
    r.totalMin = Int(jsRound((inT - startMs) / 60000))
    r.blockMin = Int(jsRound((inT - t.out) / 60000))
    r.airMin = Int(jsRound((on - off) / 60000))
    r.total = hrs(r.totalMin)
    r.nightMin = nightMinutes(t, a.p, b.p)
    r.night = hrs(r.nightMin)
    r.nightTO = isNightOp(off, a.p)
    r.nightLdg = isNightOp(on, b.p)
    r.distNm = Int(jsRound(distNm(a.p, b.p)))
    let pf = (f.duty.isEmpty ? "PF" : f.duty) == "PF"
    r.landings = pf ? 1 : 0
    r.fsNight = pf && r.nightLdg ? 1 : 0
    r.fsDay = pf && !r.nightLdg ? 1 : 0
    r.takeoffs = pf ? 1 : 0
    r.nightTakeoffs = pf && r.nightTO ? 1 : 0
    r.ok = true
    return r
}

// MARK: - Formatting shared by every screen

/// 0:00 style without a leading zero hour (Settings → Show hours as)
func fmtMin(_ min: Int, _ timeFmt: String) -> String {
    let m = max(0, min)
    if timeFmt == "dec" { return String(format: "%.2f", Double(m) / 60) }
    return "\(m / 60):\(String(format: "%02d", m % 60))"
}

/// 03:10 style (CDU panel)
func fmtHM(_ min: Int?) -> String {
    guard let min else { return "--:--" }
    return String(format: "%02d:%02d", min / 60, min % 60)
}

func fltNo(_ n: String) -> String { "Flt \(n)" }

/// 1834Z
func zt(_ ms: Double) -> String {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
    let d = c.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: ms / 1000))
    return String(format: "%02d%02dZ", d.hour ?? 0, d.minute ?? 0)
}
