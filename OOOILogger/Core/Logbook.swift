import Foundation

// Stats, Map and Search logic, ported from logbook.js.

// MARK: - Dates and numbers

private let utcCal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private var fmtCache: [String: DateFormatter] = [:]
func dateFormatter(_ format: String, utc: Bool = true) -> DateFormatter {
    let key = format + (utc ? "|u" : "|l")
    if let f = fmtCache[key] { return f }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.timeZone = utc ? TimeZone(identifier: "UTC") : .current
    f.dateFormat = format
    fmtCache[key] = f
    return f
}

func isoToDate(_ iso: String) -> Date? {
    guard let ms = isoDayMs(String(iso.prefix(10))) else { return nil }
    return Date(timeIntervalSince1970: ms / 1000 + 12 * 3600)
}

enum DateStyle: String { case medium = "MMM d, yyyy", monthShort = "MMM", monthYear = "MMMM yyyy", weekdayDay = "EEE, MMM d", monthLong = "MMMM" }
func fmtDate(_ iso: String?, _ style: DateStyle = .medium) -> String {
    guard let iso, !iso.isEmpty, let d = isoToDate(iso) else { return "—" }
    return dateFormatter(style.rawValue).string(from: d)
}

func addDays(_ iso: String, _ n: Int) -> String {
    guard let d = isoToDate(iso), let x = utcCal.date(byAdding: .day, value: n, to: d) else { return iso }
    let c = utcCal.dateComponents([.year, .month, .day], from: x)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

func todayIso() -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

private let numFmt: [Int: NumberFormatter] = {
    var m: [Int: NumberFormatter] = [:]
    for d in 0...2 {
        let f = NumberFormatter(); f.locale = Locale(identifier: "en_US"); f.numberStyle = .decimal
        f.minimumFractionDigits = d; f.maximumFractionDigits = d; m[d] = f
    }
    return m
}()
func fmtNum(_ v: Double, _ d: Int = 0) -> String { numFmt[d]!.string(from: NSNumber(value: v)) ?? String(v) }
func fmtNum(_ v: Int) -> String { fmtNum(Double(v)) }

/// Hours as 3:49 (default) or 3.8
func fmtH(_ v: Double, _ timeFmt: String) -> String {
    if timeFmt == "dec" { return fmtNum(v, 1) }
    let m = Int(jsRound(v * 60))
    return "\(fmtNum(m / 60)):\(String(format: "%02d", m % 60))"
}
/// with a unit only when decimal
func fmtHu(_ v: Double, _ timeFmt: String) -> String { timeFmt == "dec" ? "\(fmtH(v, timeFmt)) h" : fmtH(v, timeFmt) }

func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String { n == 1 ? one : (many ?? one + "s") }

// MARK: - Entries

func appEntries(_ flights: [Flight], _ cfg: Cfg) -> [LogEntry] {
    var out: [LogEntry] = []
    for f in flights {
        guard let vals = csvValues(f, cfg) else { continue }
        let get: (String) -> String = { k in f.override[k] ?? vals[k] ?? "" }
        let n: (String) -> Double = { Double(get($0)) ?? 0 }
        var e = LogEntry(d: f.date, r: [apCode(f.from), apCode(f.to)], t: n("Total Flight Time"))
        e.pic = n("PIC"); e.sic = n("SIC"); e.n = n("Night"); e.x = n("X-Country")
        e.l = Int(n("Landings")); e.ld = Int(n("FS Day Landings")); e.ln = Int(n("FS Night Landings"))
        e.to = Int(n("Takeoffs (any)")); e.ton = Int(n("Takeoffs - Night"))
        e.reg = f.tail; e.m = cfg.model; e.fn = f.flightNumber; e.src = "app"; e.flightID = f.id; e.duty = f.duty.isEmpty ? "PF" : f.duty
        out.append(e)
    }
    return out
}

/// All entries, oldest first. A history row on the same date and route as a flight logged here is the
/// same flight after it was imported into MyFlightbook, so the logged copy wins.
func allEntries(hist: [LogEntry], app: [LogEntry]) -> [LogEntry] {
    let key: (LogEntry) -> String = { "\($0.d)|\($0.r.first ?? "")|\($0.r.last ?? "")" }
    let seen = Set(app.map(key))
    let h = hist.filter { !(!$0.r.isEmpty && seen.contains(key($0))) }.map { e -> LogEntry in var x = e; x.src = "mfb"; return x }
    return (h + app).enumerated().sorted { a, b in a.element.d != b.element.d ? a.element.d < b.element.d : a.offset < b.offset }.map(\.element)
}

func periodOptions(_ entries: [LogEntry]) -> [(String, String)] {
    let years = Set(entries.map { String($0.d.prefix(4)) }).sorted(by: >)
    return [("all", "All time"), ("12m", "Last 12 months"), ("90d", "Last 90 days")] + years.map { ($0, $0) }
}
func inPeriod(_ entries: [LogEntry], _ p: String) -> [LogEntry] {
    if p == "all" { return entries }
    if p == "12m" || p == "90d" { let from = addDays(todayIso(), p == "12m" ? -365 : -90); return entries.filter { $0.d > from } }
    return entries.filter { $0.d.hasPrefix(p) }
}

func legs(_ e: LogEntry) -> [(String, String)] {
    var out: [(String, String)] = []
    if e.r.count > 1 { for i in 1..<e.r.count where e.r[i] != e.r[i - 1] { out.append((e.r[i - 1], e.r[i])) } }
    return out
}
func entryNm(_ e: LogEntry) -> Double {
    legs(e).reduce(0) { s, l in
        if let a = AP[l.0], let b = AP[l.1] { return s + distNm(a.p, b.p) }
        return s
    }
}

// MARK: - Currency (14 CFR 61.57)

struct Recency { var until: String?; var current: Bool; var in90: Int }
func recency(_ entries: [LogEntry], _ count: (LogEntry) -> Int) -> Recency {
    let today = todayIso(), from = addDays(today, -90)
    var n = 0, third: String?, in90 = 0
    for e in entries.reversed() {
        let c = count(e); if c == 0 { continue }
        if e.d > from && e.d <= today { in90 += c }
        if third == nil { n += c; if n >= 3 { third = e.d } }
    }
    let until = third.map { addDays($0, 90) }
    return Recency(until: until, current: until != nil && until! >= today, in90: in90)
}
struct CurrencyKind { var to: Recency; var ldg: Recency; var until: String?; var current: Bool }
struct Currency { var day: CurrencyKind; var night: CurrencyKind; var noTo: Bool }
func currencyStatus(_ entries: [LogEntry]) -> Currency {
    let noTo = entries.contains { $0.to == nil && $0.l != 0 }
    let to: (LogEntry) -> Int = { $0.to ?? $0.l }, ton: (LogEntry) -> Int = { $0.ton ?? $0.ln }
    func merge(_ a: Recency, _ b: Recency) -> CurrencyKind {
        let until: String? = (a.until != nil && b.until != nil) ? min(a.until!, b.until!) : nil
        return CurrencyKind(to: a, ldg: b, until: until, current: a.current && b.current)
    }
    return Currency(day: merge(recency(entries, to), recency(entries, { $0.l })),
                    night: merge(recency(entries, ton), recency(entries, { $0.ln })), noTo: noTo)
}

// MARK: - Totals and buckets

struct Totals { var flights = 0, sims = 0; var total = 0.0, pic = 0.0, sic = 0.0, night = 0.0, xc = 0.0; var l = 0, ln = 0; var nm = 0.0; var airports = 0 }
func totals(_ es: [LogEntry]) -> Totals {
    var t = Totals(); var aps = Set<String>()
    for e in es {
        if e.sim { t.sims += 1 } else { t.flights += 1 }
        t.total += e.t; t.pic += e.pic; t.sic += e.sic; t.night += e.n; t.xc += e.x; t.l += e.l; t.ln += e.ln
        t.nm += entryNm(e)
        for a in e.r where AP[a] != nil { aps.insert(a) }
    }
    t.airports = aps.count
    return t
}

struct Bucket: Identifiable { var key: String; var label: String; var full: String; var t: Totals; var id: String { key } }
func buckets(_ es: [LogEntry], _ p: String) -> (byYear: Bool, rows: [Bucket]) {
    let byYear = p == "all"
    var keys: [String] = []
    if byYear {
        let ys = es.compactMap { Int($0.d.prefix(4)) }
        if let lo = ys.min(), let hi = ys.max() { for y in lo...hi { keys.append(String(y)) } }
    } else if p.count == 4, Int(p) != nil {
        for m in 1...12 { keys.append(String(format: "%@-%02d", p, m)) }
    } else {
        let n = p == "90d" ? 3 : 12
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        for i in stride(from: n - 1, through: 0, by: -1) {
            var y = c.year ?? 2000, m = (c.month ?? 1) - i
            while m < 1 { m += 12; y -= 1 }
            keys.append(String(format: "%04d-%02d", y, m))
        }
    }
    var groups: [String: [LogEntry]] = [:]
    for k in keys { groups[k] = [] }
    for e in es { let k = byYear ? String(e.d.prefix(4)) : String(e.d.prefix(7)); if groups[k] != nil { groups[k]!.append(e) } }
    return (byYear, keys.map { k in
        Bucket(key: k, label: byYear ? k : fmtDate(k + "-15", .monthShort), full: byYear ? k : fmtDate(k + "-15", .monthYear), t: totals(groups[k] ?? []))
    })
}

// MARK: - Search (Stats → Search)

let FDOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
let FMON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
let FCHIPS: [(String, String)] = [("night", "Night time"), ("nldg", "Night landing"), ("ldg", "Landed (PF)"), ("noldg", "No landing (PM)"),
                                  ("pic", "PIC"), ("sic", "SIC"), ("app", "Logged here"), ("mfb", "From MyFlightbook")]
let FSORT: [(String, String)] = [("new", "Newest"), ("old", "Oldest"), ("long", "Longest time"), ("night", "Most night"), ("dist", "Longest distance")]

struct FindState: Equatable {
    var q = ""
    var st: Set<String> = []
    var f: [String: String] = [:]
    var sort = "new"
    var nFilters: Int { f.values.filter { !$0.isEmpty }.count + (sort != "new" ? 1 : 0) }
}

/// An airport box matches ICAO or a 3-letter US code (FLL finds KFLL), and a partly typed code.
func apIs(_ code: String?, _ v: String) -> Bool {
    guard let code, !code.isEmpty, !v.isEmpty else { return false }
    let v = v.uppercased()
    return code.hasPrefix(v) || (v.count <= 3 && code.hasPrefix("K") && code.dropFirst().hasPrefix(v))
}
func eDow(_ e: LogEntry) -> Int {
    guard let d = isoToDate(e.d) else { return 0 }
    return utcCal.component(.weekday, from: d) - 1
}
func parseHrs(_ v: String?) -> Double? {
    let s = (v ?? "").trimmingCharacters(in: .whitespaces)
    let parts = s.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (1...2).contains(parts[1].count), m < 60 { return Double(h) + Double(m) / 60 }
    return s.isEmpty ? nil : Double(s)
}
private func isK3(_ c: String) -> Bool { c.count == 4 && c.hasPrefix("K") && c.allSatisfy { $0.isASCII && $0.isUppercase } }
func eHay(_ e: LogEntry) -> String {
    let codes = e.r.flatMap { isK3($0) ? [$0, String($0.dropFirst())] : [$0] }
    let s3: (String) -> String = { isK3($0) ? String($0.dropFirst()) : $0 }
    let lg = legs(e).flatMap { a, b in ["\(a)-\(b)", "\(a)\(b)", "\(s3(a))-\(s3(b))", "\(s3(a))\(s3(b))"] }
    let mo = (Int(e.d.dropFirst(5).prefix(2)) ?? 1) - 1
    var parts: [String] = codes + lg
    parts += [e.fn, e.fn.isEmpty ? "" : "flt\(e.fn)", e.reg, e.m, e.d, String(e.d.prefix(4)), FMON[max(0, min(11, mo))], fmtDate(e.d, .monthLong), FDOW[eDow(e)]]
    if e.n > 0 { parts.append("night") }
    if e.ln > 0 { parts.append("nightlanding") }
    if e.pic > 0 { parts.append("pic") }
    if e.sic > 0 { parts.append("sic") }
    if e.sim { parts.append("sim simulator") }
    parts.append(e.src == "app" ? "logged here" : "myflightbook mfb")
    if let d = e.duty { parts.append(d.lowercased()) }
    return parts.filter { !$0.isEmpty }.joined(separator: " ").lowercased()
}
func fChip(_ e: LogEntry, _ k: String) -> Bool {
    switch k {
    case "night": return e.n > 0
    case "nldg": return e.ln > 0
    case "ldg": return e.l > 0
    case "noldg": return e.l == 0 && !e.sim
    case "pic": return e.pic > 0
    case "sic": return e.sic > 0
    case "app": return e.src == "app"
    case "mfb": return e.src != "app"
    default: return true
    }
}

func applyFind(_ all: [LogEntry], _ F: FindState) -> [LogEntry] {
    let g: (String) -> String = { (F.f[$0] ?? "").trimmingCharacters(in: .whitespaces) }
    let toks = F.q.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let routeParts = g("route").uppercased().replacingOccurrences(of: "[^A-Z0-9]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
    let rd = routeParts.first ?? "", ra = routeParts.count > 1 ? routeParts[1] : ""
    let minH = parseHrs(g("min")), maxH = parseHrs(g("max"))
    var hay: [UUID: String] = [:]
    let out = all.filter { e in
        if !g("year").isEmpty && !e.d.hasPrefix(g("year")) { return false }
        if !g("since").isEmpty && e.d < g("since") { return false }
        if !g("mo").isEmpty && Int(e.d.dropFirst(5).prefix(2)) != Int(g("mo")) { return false }
        if !g("dow").isEmpty && String(eDow(e)) != g("dow") { return false }
        let first = e.r.first, last = e.r.last
        if !g("dep").isEmpty && !apIs(first, g("dep")) { return false }
        if !g("arr").isEmpty && !apIs(last, g("arr")) { return false }
        if !g("ap").isEmpty && !e.r.contains(where: { apIs($0, g("ap")) }) { return false }
        if !rd.isEmpty {
            let lg = legs(e)
            let hit: (String, String) -> Bool = { a, b in lg.contains { apIs($0.0, a) && (b.isEmpty || apIs($0.1, b)) } }
            if !hit(rd, ra) && !(!g("both").isEmpty && !ra.isEmpty && hit(ra, rd)) { return false }
        }
        if !g("tail").isEmpty && !e.reg.uppercased().contains(g("tail").uppercased()) { return false }
        if !g("ac").isEmpty && e.m != g("ac") { return false }
        for k in F.st where !fChip(e, k) { return false }
        if let minH, !(e.t >= minH - 1e-9) { return false }
        if let maxH, !(e.t <= maxH + 1e-9) { return false }
        for t in toks {
            if let m = t.range(of: #"^([<>]=?)(\d+(?::[0-5]?\d|\.\d+)?)$"#, options: .regularExpression), m.lowerBound == t.startIndex {
                let op = t.prefix { $0 == "<" || $0 == ">" || $0 == "=" }
                let n = parseHrs(String(t.dropFirst(op.count))) ?? 0
                if !(op.hasPrefix(">") ? e.t >= n : e.t <= n) { return false }
            } else {
                let h = hay[e.uid] ?? eHay(e); hay[e.uid] = h
                if !h.contains(t) { return false }
            }
        }
        return true
    }
    switch F.sort {
    case "old": return out.sorted { $0.d < $1.d }
    case "long": return out.sorted { $0.t > $1.t }
    case "night": return out.sorted { $0.n > $1.n }
    case "dist": return out.sorted { entryNm($0) > entryNm($1) }
    default: return out.sorted { $0.d > $1.d }
    }
}

// MARK: - Map

struct MapData { var aps: [String: (n: Int, first: String, last: String)] = [:]; var routes: [String: Int] = [:] }
func mapData(_ es: [LogEntry]) -> MapData {
    var d = MapData()
    for e in es where !e.sim {
        for a in Set(e.r) where AP[a] != nil {
            if var x = d.aps[a] { x.n += 1; x.last = e.d; d.aps[a] = x } else { d.aps[a] = (1, e.d, e.d) }
        }
        for (a, b) in legs(e) where AP[a] != nil && AP[b] != nil {
            let k = [a, b].sorted().joined(separator: "|"); d.routes[k, default: 0] += 1
        }
    }
    return d
}

struct MapView_ { var x: Double; var y: Double; var w: Double; var h: Double; var k: Double }

/// Keep the view's centre on the middle world copy, no wider than one world, and inside the poles.
func clampView(_ v0: MapView_) -> MapView_ {
    var v = v0
    let period = 360 * v.k
    if v.w > period { let f = period / v.w; v = MapView_(x: v.x + (v.w - period) / 2, y: v.y + (v.h - v.h * f) / 2, w: period, h: v.h * f, k: v.k) }
    var cx = v.x + v.w / 2
    while cx > period / 2 { v.x -= period; cx -= period }
    while cx < -period / 2 { v.x += period; cx += period }
    if v.h >= 180 { v.y = -v.h / 2 } else { v.y = min(max(v.y, -90), 90 - v.h) }
    return v
}
func fitView(_ codes: [String]) -> MapView_ {
    let pts = codes.compactMap { AP[$0] }
    guard !pts.isEmpty else { return clampView(MapView_(x: -180, y: -80, w: 360, h: 160, k: 1)) }
    let minLat = pts.map(\.lat).min()!, maxLat = pts.map(\.lat).max()!
    // Smallest longitude span that holds every airport, allowing it to cross the date line.
    let L = Array(Set(pts.map(\.lon))).sorted()
    var gap = -1.0, gi = 0
    for i in 0..<L.count { let g = (i + 1 < L.count ? L[i + 1] : L[0] + 360) - L[i]; if g > gap { gap = g; gi = i } }
    let minLon = L.count > 1 ? (gi + 1 < L.count ? L[gi + 1] : L[0]) : L[0]
    let maxLon = minLon + (L.count > 1 ? 360 - gap : 0)
    let k = cos((minLat + maxLat) / 2 * RAD)
    var w = (maxLon - minLon) * k, h = maxLat - minLat
    let pad = max(2, max(w, h) * 0.1); w += pad * 2; h += pad * 2
    if w / h < 1.3 { w = h * 1.3 } else { h = max(h, w / 1.9) }
    return clampView(MapView_(x: (minLon + maxLon) / 2 * k - w / 2, y: -(minLat + maxLat) / 2 - h / 2, w: w, h: h, k: k))
}
/// great-circle samples with continuous longitude (no split at the date line), as (lon, -lat)
func arc(_ a: LatLon, _ b: LatLon) -> [(Double, Double)] {
    var out: [(Double, Double)] = []; var prev: Double?
    for i in 0...32 {
        let p = gcPoint(a, b, Double(i) / 32); var lon = p.lon
        if let pv = prev { while lon - pv > 180 { lon -= 360 }; while pv - lon > 180 { lon += 360 } }
        out.append((lon, -p.lat)); prev = lon
    }
    return out
}
