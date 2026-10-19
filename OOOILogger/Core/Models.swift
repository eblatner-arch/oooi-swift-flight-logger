import Foundation

// MARK: - JSON helpers (the add-on's JSON is hand-built, so read it leniently)

typealias JSON = [String: Any]

func jstr(_ v: Any?) -> String {
    switch v {
    case let s as String: return s
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        let d = n.doubleValue
        return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
    default: return ""
    }
}
func jnum(_ v: Any?) -> Double {
    switch v {
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s) ?? 0
    default: return 0
    }
}
func jbool(_ v: Any?) -> Bool {
    switch v {
    case let b as Bool: return b
    case let n as NSNumber: return n.boolValue
    case let s as String: return s == "true" || s == "1"
    default: return false
    }
}
func jdict(_ v: Any?) -> JSON { v as? JSON ?? [:] }
func jarr(_ v: Any?) -> [Any] { v as? [Any] ?? [] }
func jstrDict(_ v: Any?) -> [String: String] {
    var out: [String: String] = [:]
    for (k, x) in jdict(v) { out[k] = jstr(x) }
    return out
}

// MARK: - Flight (same fields as flights.json on the add-on)

struct Flight: Identifiable, Equatable {
    var id = ""
    var date = ""
    var flightNumber = ""
    var tail = ""
    var from = ""
    var to = ""
    var crew = ""
    var out = ""
    var off = ""
    var on = ""
    var inTime = ""
    var comments = ""
    var duty = "PF"
    var seat = ""
    var approaches = 0
    var imported = false
    var createdAt = ""
    var updatedAt = ""
    var extra: [String: String] = [:]
    var override: [String: String] = [:]

    init() {}

    init(json j: JSON) {
        id = jstr(j["id"]); date = jstr(j["date"]); flightNumber = jstr(j["flightNumber"]); tail = jstr(j["tail"])
        from = jstr(j["from"]); to = jstr(j["to"]); crew = jstr(j["crew"]); out = jstr(j["out"]); off = jstr(j["off"])
        on = jstr(j["on"]); inTime = jstr(j["in"]); comments = jstr(j["comments"])
        duty = jstr(j["duty"]); if duty.isEmpty { duty = "PF" }
        seat = jstr(j["seat"]); approaches = Int(jnum(j["approaches"])); imported = jbool(j["imported"])
        createdAt = jstr(j["createdAt"]); updatedAt = jstr(j["updatedAt"])
        extra = jstrDict(j["extra"]); override = jstrDict(j["override"])
    }

    /// The body the Log screen PUTs (readForm in app-ha.js).
    var putBody: JSON {
        ["date": date, "flightNumber": flightNumber, "tail": tail, "from": from, "to": to, "crew": crew, "out": out,
         "off": off, "on": on, "in": inTime, "comments": comments, "duty": duty, "seat": seat, "approaches": approaches,
         "extra": extra, "override": override]
    }

    var sortKey: String { date + out }
}

struct CsvExtra: Equatable, Identifiable {
    var id: String
    var name: String
    var source: String
    var text: String
    var json: JSON { ["id": id, "name": name, "source": source, "text": text] }
}

/// S.cfg in app-ha.js
struct Cfg: Equatable {
    var seat = "PIC"
    var anonTail = "#002377"
    var model = "B737"
    var csvNames: [String: String] = [:]
    var csvOff: [String] = []
    var csvExtra: [CsvExtra] = []
    var csvShow: [String] = []
    var timeFmt = "hm"

    init() {}
    init(settings s: JSON) {
        seat = jstr(s["seat"]).isEmpty ? "PIC" : jstr(s["seat"])
        anonTail = jstr(s["anon_tail"]).isEmpty ? "#002377" : jstr(s["anon_tail"])
        model = jstr(s["model"]).isEmpty ? "B737" : jstr(s["model"])
        csvNames = jstrDict(s["csv_names"])
        csvOff = jarr(s["csv_off"]).map(jstr)
        csvExtra = jarr(s["csv_extra"]).map { x in
            let d = jdict(x)
            return CsvExtra(id: jstr(d["id"]), name: jstr(d["name"]), source: jstr(d["source"]).isEmpty ? "text" : jstr(d["source"]), text: jstr(d["text"]))
        }
        csvShow = jarr(s["csv_show"]).map(jstr)
        timeFmt = jstr(s["time_fmt"]) == "dec" ? "dec" : "hm"
    }
}

struct DrivePending: Equatable {
    var userCode = ""
    var verificationURL = ""
    var error: String?
}

struct DriveInfo: Equatable {
    var configured = false
    var connected = false
    var email = ""
    var lastSync: String?
    var lastError: String?
    var folderID: String?
    var folder = ""
    var syncing = false
    var pending: DrivePending?

    init() {}
    init(json d: JSON) {
        configured = jbool(d["configured"]); connected = jbool(d["connected"]); email = jstr(d["email"])
        lastSync = d["last_sync"] as? String; lastError = d["last_error"] as? String
        if lastError?.isEmpty == true { lastError = nil }
        folderID = d["folder_id"] as? String; folder = jstr(d["folder"]); syncing = jbool(d["syncing"])
        if let p = d["pending"] as? JSON {
            pending = DrivePending(userCode: jstr(p["user_code"]), verificationURL: jstr(p["verification_url"]), error: p["error"] as? String)
        }
    }
}

struct AirportsInfo: Equatable {
    var source = "bundled"
    var updated: String?
    var count = 0
}

struct HistoryInfo: Equatable {
    var importedAt = ""
    var file = ""
    var flights = 0
    var simSessions = 0
    var first = ""
    var last = ""
    var totalHours = 0.0
    var unknownAirports: [String] = []
    var unknownCount = 0

    init?(json v: Any?) {
        guard let h = v as? JSON, let imp = h["imported_at"] as? String else { return nil }
        importedAt = imp; file = jstr(h["file"]); flights = Int(jnum(h["flights"])); simSessions = Int(jnum(h["sim_sessions"]))
        first = jstr(h["first"]); last = jstr(h["last"]); totalHours = jnum(h["total_hours"])
        unknownAirports = jarr(h["unknown_airports"]).map(jstr); unknownCount = Int(jnum(h["unknown_airport_count"]))
    }
}

/// One row for Stats, Map and Search: imported MyFlightbook history, or a flight logged here.
struct Entry: Identifiable {
    var d: String
    var r: [String]
    var t: Double
    var pic = 0.0, sic = 0.0, n = 0.0, x = 0.0
    var l = 0, ld = 0, ln = 0
    var to: Int?
    var ton: Int?
    var reg = ""
    var m = ""
    var fn = ""
    var sim = false
    var src = "mfb"
    var flightID: String?
    var duty: String?
    var uid = UUID()
    var id: UUID { uid }

    init(d: String, r: [String], t: Double) { self.d = d; self.r = r; self.t = t }

    init(json e: JSON) {
        d = jstr(e["d"]); r = jarr(e["r"]).map(jstr); t = jnum(e["t"])
        pic = jnum(e["pic"]); sic = jnum(e["sic"]); n = jnum(e["n"]); x = jnum(e["x"])
        l = Int(jnum(e["l"])); ld = Int(jnum(e["ld"])); ln = Int(jnum(e["ln"]))
        to = e["to"].map { Int(jnum($0)) }; ton = e["ton"].map { Int(jnum($0)) }
        reg = jstr(e["reg"]); m = jstr(e["m"]); fn = jstr(e["fn"]); sim = jbool(e["sim"])
    }
}
