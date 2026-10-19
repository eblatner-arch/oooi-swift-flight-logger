import Foundation

// MyFlightbook CSV, ported from core.js. Home Assistant builds the real files; the app uses this for
// the grey "automatic" values on the Log screen, Stats, and a CSV when Home Assistant can't be reached.

let CSV_COLS = ["Date", "Tail Number", "Model", "Landings", "FS Night Landings", "FS Day Landings", "X-Country", "Night", "SIC", "PIC",
                "Total Flight Time", "Route", "Comments", "Aircraft Registration", "Flight Number", "Crew Start Time (UTC)",
                "Block Out Time", "Flight Start", "Flight End", "Block In Time", "Takeoffs (any)", "Takeoffs - Night"]
/// Values a user-added column can copy, besides any standard column.
let EXTRA_SOURCES = ["Block Time (OUT to IN)", "Air Time (OFF to ON)", "Departure", "Arrival", "Pilot Duty (PF/PM)"]
let CSV_SOURCES = CSV_COLS + EXTRA_SOURCES
/// Standard columns the Log screen already has a box for (everything else can get an Edit box).
let ON_LOG_SCREEN: Set<String> = ["Date", "Flight Number", "Route", "Aircraft Registration", "Comments", "Crew Start Time (UTC)",
                                  "Block Out Time", "Flight Start", "Flight End", "Block In Time"]
/// CSV columns that hold hours (edit boxes show and accept H:MM for these).
let HOUR_SRC: Set<String> = ["X-Country", "Night", "SIC", "PIC", "Total Flight Time", "Block Time (OUT to IN)", "Air Time (OFF to ON)"]

/// 4.80 → "4.8", 4.00 → "4.0" (same as toFixed(2).replace(/0$/,'').replace(/\.$/,''))
func dec(_ v: Double) -> String {
    var s = String(format: "%.2f", v)
    if s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}
func hrsMs(_ ms: Double) -> Double { jsRound(jsRound(ms / 60000) / 60 * 100) / 100 }

func mfbTime(_ ms: Double?) -> String {
    guard let ms else { return "" }
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
    let d = c.dateComponents([.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: ms / 1000))
    return "\(d.month ?? 0)/\(d.day ?? 0)/\(d.year ?? 0) " + String(format: "%02d:%02d", d.hour ?? 0, d.minute ?? 0)
}
func mfbDate(_ iso: String) -> String {
    let p = iso.split(separator: "-")
    guard p.count == 3 else { return iso }
    return "\(Int(p[1]) ?? 0)/\(Int(p[2]) ?? 0)/\(p[0])"
}

/// Every value a CSV cell can hold for this flight, by column name (nil if the flight is incomplete).
func csvValues(_ f: Flight, _ cfg: Cfg) -> [String: String]? {
    let r = compute(f)
    guard r.ok, let t = r.t else { return nil }
    let tot = dec(r.total)
    let seat = !f.seat.isEmpty ? f.seat : (cfg.seat.isEmpty ? "PIC" : cfg.seat)
    let num: (Int) -> String = { $0 != 0 ? String($0) : "" }
    return [
        "Date": mfbDate(f.date), "Tail Number": cfg.anonTail, "Model": cfg.model,
        "Approaches": String(f.approaches), "Landings": String(r.landings),
        "FS Night Landings": String(r.fsNight), "FS Day Landings": String(r.fsDay),
        "X-Country": tot, "Night": r.nightMin != 0 ? dec(r.night) : "",
        "SIC": seat == "SIC" ? tot : "", "PIC": seat == "PIC" ? tot : "", "Total Flight Time": tot,
        "Route": "\(f.from) \(f.to)", "Comments": f.comments,
        "Aircraft Registration": f.tail, "Flight Number": f.flightNumber,
        "Crew Start Time (UTC)": mfbTime(t.crew), "Block Out Time": mfbTime(t.out), "Engine Start": mfbTime(t.out),
        "Flight Start": mfbTime(t.off), "Flight End": mfbTime(t.on), "Engine End": mfbTime(t.inT), "Block In Time": mfbTime(t.inT),
        "Takeoffs (any)": num(r.takeoffs), "Takeoffs - Night": num(r.nightTakeoffs),
        "Block Time (OUT to IN)": dec(hrsMs((t.inT ?? 0) - t.out)), "Air Time (OFF to ON)": dec(hrsMs((t.on ?? 0) - (t.off ?? 0))),
        "Departure": f.from, "Arrival": f.to, "Pilot Duty (PF/PM)": f.duty.isEmpty ? "PF" : f.duty,
    ]
}

enum CellKind { case col, field, text }
struct CsvCell { let kind: CellKind; let v: String; let key: String? }

/// Columns to write and their header text.
func csvLayout(_ cfg: Cfg) -> (cells: [CsvCell], headers: [String]) {
    let off = Set(cfg.csvOff)
    let std = CSV_COLS.filter { !off.contains($0) }
    var cells = std.map { CsvCell(kind: .col, v: $0, key: $0) }
    var headers = std.map { c -> String in
        let n = (cfg.csvNames[c] ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? c : n
    }
    for x in cfg.csvExtra {
        let src = x.source.isEmpty ? "text" : x.source
        if src == "field" { cells.append(CsvCell(kind: .field, v: x.id, key: nil)) }
        else if src == "text" { cells.append(CsvCell(kind: .text, v: x.text, key: x.id)) }
        else { cells.append(CsvCell(kind: .col, v: src, key: x.id)) }
        headers.append(x.name)
    }
    return (cells, headers)
}

func csvCell(_ v: String) -> String {
    v.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" }) ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
}

func csvRow(_ f: Flight, _ cfg: Cfg) -> String? {
    guard let row = csvValues(f, cfg) else { return nil }
    return csvLayout(cfg).cells.map { c -> String in
        if let k = c.key, let o = f.override[k] { return csvCell(o) }
        switch c.kind {
        case .col: return csvCell(row[c.v] ?? "")
        case .field: return csvCell(f.extra[c.v] ?? "")
        case .text: return csvCell(c.v)
        }
    }.joined(separator: ",")
}

func buildCsv(_ flights: [Flight], _ cfg: Cfg) -> String {
    let rows = flights.sorted { $0.sortKey < $1.sortKey }.compactMap { csvRow($0, cfg) }
    return csvLayout(cfg).headers.map(csvCell).joined(separator: ",") + "\n" + rows.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
}

// MARK: - H:MM in edit boxes

func decToMin(_ v: String) -> Int? {
    let s = v.trimmingCharacters(in: .whitespaces)
    guard s.range(of: #"^\d*\.?\d+$"#, options: .regularExpression) != nil, let d = Double(s) else { return nil }
    return Int(jsRound(d * 60))
}
/// "1:16" → "1.27" for the CSV; anything else is kept as typed.
func toCsvHours(_ v: String) -> String {
    let s = v.trimmingCharacters(in: .whitespaces)
    let parts = s.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), parts[0].allSatisfy(\.isNumber),
          (1...2).contains(parts[1].count), m < 60 else { return s }
    return dec(jsRound(Double(h * 60 + m) / 60 * 100) / 100)
}
func showHours(_ v: String, _ timeFmt: String) -> String {
    guard let m = decToMin(v) else { return v }
    return fmtMin(m, timeFmt)
}
