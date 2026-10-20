import SwiftUI
import UIKit

/// A change waiting to reach Home Assistant. Saved to disk so nothing is lost while offline.
struct OutOp: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var method: String
    var path: String
    var body: Data?
}

enum Conn: Equatable { case notSetUp, connecting, ok, offline, needsLogin }

enum AppTab: String, CaseIterable { case log, list, stats, map, set
    var title: String { ["log": "Log", "list": "Flights", "stats": "Stats", "map": "Map", "set": "Settings"][rawValue]! }
}

/// The Log screen's boxes (readForm in app-ha.js).
struct FormState: Equatable {
    var date = todayIso()
    var flightNumber = "", tail = "", from = "", to = ""
    var crew = "", out = "", off = "", on = "", inTime = ""
    var comments = ""
    var duty = "PF"
    var seat = "PIC"
    /// Boxes under Comments, keyed "field:<id>" or "ov:<column>"
    var custom: [String: String] = [:]
}

/// A box under Comments: a "fill in" column, or an Edit box over an automatic value.
struct LogBox: Identifiable, Equatable {
    var kind: String      // "field" or "ov"
    var key: String
    var label: String
    var def = ""
    var src = ""
    var text = ""
    var isText = false
    var id: String { kind + ":" + key }
}

struct ScanMsg: Equatable { var kind: MsgKind; var text: String }

enum Focus: Hashable { case date, flightNumber, tail, from, to, crew, out, off, on, inTime, comments, custom(String) }

@MainActor
final class AppModel: ObservableObject {
    // Navigation
    @Published var tab: AppTab = .log
    @Published var night = false
    @Published var scrollToken = 0
    @Published var scrollBottomToken = 0

    // Data from Home Assistant (plus changes still waiting in the outbox)
    @Published private(set) var flights: [Flight] = []
    @Published private(set) var cfg = Cfg()
    @Published private(set) var drive = DriveInfo()
    @Published private(set) var scanConfigured = false
    @Published private(set) var scanModel = ""
    @Published private(set) var airports = AirportsInfo()
    @Published private(set) var historyInfo: HistoryInfo?
    @Published private(set) var csvCols = CSV_COLS
    @Published private(set) var csvSources = CSV_SOURCES
    @Published private(set) var loaded = false
    @Published private(set) var hist: [LogEntry] = []
    @Published private(set) var histKey: String?
    @Published private(set) var unknownN = 0
    @Published private(set) var conn: Conn = .connecting
    @Published private(set) var outbox: [OutOp] = []
    @Published private(set) var apVersion = 0
    @Published var syncingNow = false

    // UI state
    @Published var toastText: String?
    @Published var form = FormState()
    @Published private(set) var editId: String?
    @Published var scannedTrip: Int?
    @Published var scanMsg: ScanMsg?
    @Published var scanTiming: String?
    @Published var thumb: UIImage?
    @Published var focusRequest: Focus?
    @Published var showDelConfirm = false
    @Published var statsView = "overview"
    @Published var period = "all"
    @Published var find = FindState()
    @Published var findMoreOpen = false
    @Published var shareFile: ShareItem?

    private var serverFlights: [Flight] = []
    private var settingsJSON: JSON = [:]
    private var refreshing = false
    private var flushing = false
    private var toastTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    let api = API.shared

    init() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: Self.file("outbox.json")), let o = try? JSONDecoder().decode([OutOp].self, from: d) { outbox = o }
        // Draw from the copy on the phone first, then bring it up to date from Home Assistant.
        if let d = try? Data(contentsOf: Self.file("state.json")), applyState(d) { loaded = true }
        if !api.configured { conn = .notSetUp }
        newFlight(keepDate: false)
        loadAirports()
        Task { await loadCachedHistory() }
        Land.shared.load()
    }

    // MARK: - Disk

    static let dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OOOI", isDirectory: true)
    static func file(_ name: String) -> URL { dir.appendingPathComponent(name) }
    private func saveOutbox() { if let d = try? JSONEncoder().encode(outbox) { try? d.write(to: Self.file("outbox.json"), options: .atomic) } }

    private func loadAirports() {
        let cached = Self.file("airports.js")
        let useCached = UserDefaults.standard.string(forKey: "airportsUpdated") != nil && FileManager.default.fileExists(atPath: cached.path)
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = false
            if useCached, let s = try? String(contentsOf: cached, encoding: .utf8) { ok = Airports.shared.load(js: s) }
            if !ok, let u = Bundle.main.url(forResource: "airports", withExtension: "js"), let s = try? String(contentsOf: u, encoding: .utf8) {
                Airports.shared.load(js: s)
            }
            DispatchQueue.main.async { self.apVersion += 1 }
        }
    }

    // MARK: - State

    @discardableResult
    private func applyState(_ data: Data) -> Bool {
        guard let st = (try? JSONSerialization.jsonObject(with: data)) as? JSON, st["flights"] != nil else { return false }
        serverFlights = jarr(st["flights"]).map { Flight(json: jdict($0)) }
        drive = DriveInfo(json: jdict(st["drive"]))
        let sc = jdict(st["scan"]); scanConfigured = jbool(sc["configured"]); scanModel = jstr(sc["model"])
        let ap = jdict(st["airports"])
        airports = AirportsInfo(source: jstr(ap["source"]).isEmpty ? "bundled" : jstr(ap["source"]), updated: ap["updated"] as? String, count: Int(jnum(ap["count"])))
        historyInfo = HistoryInfo(json: st["history"])
        settingsJSON = jdict(st["settings"])
        let cols = jarr(st["csv_columns"]).map(jstr); csvCols = cols.isEmpty ? CSV_COLS : cols
        let srcs = jarr(st["csv_sources"]).map(jstr); csvSources = srcs.isEmpty ? CSV_SOURCES : srcs
        rebuild()
        return true
    }

    /// Server data with the outbox laid over it, so a change shows at once even before it uploads.
    private func rebuild() {
        var fl = serverFlights
        var s = settingsJSON
        for op in outbox {
            let body = op.body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? JSON } ?? [:]
            if op.path.hasPrefix("api/flights/") && op.path != "api/flights/mark-imported" {
                let id = String(op.path.dropFirst("api/flights/".count)).removingPercentEncoding ?? ""
                let old = fl.first { $0.id == id }
                fl.removeAll { $0.id == id }
                if op.method == "PUT" {
                    var f = Flight(json: body); f.id = id
                    f.imported = old?.imported ?? false; f.createdAt = old?.createdAt ?? ""
                    fl.append(f)
                }
            } else if op.path == "api/flights/mark-imported" {
                for i in fl.indices { fl[i].imported = true }
            } else if op.path == "api/settings" {
                for (k, v) in body { s[k] = v }
            }
        }
        flights = fl
        let newCfg = Cfg(settings: s)
        if newCfg != cfg { cfg = newCfg }
        ensureCustomDefaults()
    }

    var pendingUploads: Int { outbox.count }

    func refresh() async {
        guard api.configured else { conn = .notSetUp; return }
        if refreshing { return }
        refreshing = true; defer { refreshing = false }
        if conn != .ok && !loaded { conn = .connecting }
        _ = await flushOutbox()
        do {
            let (data, http) = try await api.raw("GET", "api/state")
            if http.statusCode == 401 { conn = .needsLogin; return }
            guard http.statusCode == 200, applyState(data) else { conn = .offline; return }
            try? data.write(to: Self.file("state.json"), options: .atomic)
            loaded = true
            conn = .ok
            await syncAirports()
            await loadHistory()
        } catch {
            if conn != .needsLogin { conn = .offline }
        }
    }

    /// After a change the add-on uploads to Drive a couple of seconds later; check back briefly.
    func watchSync() {
        watchTask?.cancel()
        watchTask = Task {
            for n in 1...6 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                await refresh()
                if !drive.syncing && n >= 3 { return }
            }
        }
    }

    // MARK: - Outbox

    private func enqueue(_ op: OutOp) {
        outbox.append(op); saveOutbox(); rebuild()
        Task {
            if await flushOutbox() { await refresh(); watchSync() }
        }
    }

    /// Send queued changes in order. Stops at the first one that can't reach Home Assistant.
    @discardableResult
    func flushOutbox() async -> Bool {
        guard api.configured else { return false }
        if flushing { return false }
        flushing = true; defer { flushing = false }
        var sent = false
        while let op = outbox.first {
            do {
                try await api.call(op.method, op.path, body: op.body, contentType: op.body == nil ? nil : "application/json")
                outbox.removeFirst(); saveOutbox(); sent = true
            } catch let e as APIError {
                if e.offline { conn = .offline; return false }
                if e.status == 401 { conn = .needsLogin; return false }
                // Home Assistant refused this change (for example a column name used twice): drop it.
                outbox.removeFirst(); saveOutbox(); rebuild(); toast(e.message)
            } catch { return false }
        }
        _ = sent
        return true
    }

    private var offlineNow: Bool { conn == .offline || conn == .notSetUp || conn == .needsLogin }

    // MARK: - Toast

    func toast(_ t: String) {
        toastText = t
        toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(nanoseconds: 3_200_000_000); if !Task.isCancelled { toastText = nil } }
    }

    // MARK: - Status line (header)

    var statusLine: (MsgKind, String) {
        switch conn {
        case .notSetUp: return (.warn, "Saved on this iPhone · Set up Home Assistant in Settings")
        case .needsLogin: return (.bad, "Log in again in Settings")
        case .offline:
            return outbox.isEmpty ? (.bad, "Cannot reach the add-on · showing saved copy")
                : (.warn, "Offline · \(outbox.count) change\(outbox.count == 1 ? "" : "s") waiting to upload")
        case .connecting where !loaded: return (.plain, "Connecting…")
        default: break
        }
        if !outbox.isEmpty { return (.plain, "Uploading \(outbox.count) change\(outbox.count == 1 ? "" : "s")…") }
        let d = drive
        if syncingNow { return (.plain, "Syncing to Drive…") }
        if !d.configured { return (.warn, "Saved on Home Assistant · Drive not set up") }
        if !d.connected { return (.warn, "Saved on Home Assistant · Connect Google") }
        if d.syncing { return (.plain, "Syncing to Drive…") }
        if d.lastError != nil { return (.bad, "Drive sync failed · see Settings") }
        if let ls = d.lastSync, let date = parseISO(ls) { return (.good, "Drive synced " + dateFormatter("MMM d 'at' h:mm a", utc: false).string(from: date)) }
        return (.plain, "Connected to Drive")
    }

    // MARK: - Log form

    var logBoxes: [LogBox] {
        let show = Set(cfg.csvShow), off = Set(cfg.csvOff)
        var out: [LogBox] = []
        for c in csvCols where show.contains(c) && !off.contains(c) && !ON_LOG_SCREEN.contains(c) {
            let n = (cfg.csvNames[c] ?? "").trimmingCharacters(in: .whitespaces)
            out.append(LogBox(kind: "ov", key: c, label: n.isEmpty ? c : n, src: c))
        }
        for x in cfg.csvExtra {
            if x.source == "field" { out.append(LogBox(kind: "field", key: x.id, label: x.name, def: x.text)) }
            else if show.contains(x.id) { out.append(LogBox(kind: "ov", key: x.id, label: x.name, src: x.source, text: x.text, isText: x.source == "text")) }
        }
        return out
    }

    private func ensureCustomDefaults() {
        guard editId == nil else { return }
        for b in logBoxes where b.kind == "field" && form.custom[b.id] == nil { form.custom[b.id] = b.def }
    }

    func readForm() -> Flight {
        var f = Flight()
        let tr: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let digits: (String) -> String = { $0.filter { $0.isASCII && $0.isNumber } }
        f.date = tr(form.date); f.flightNumber = tr(form.flightNumber); f.tail = tr(form.tail).uppercased()
        f.from = tr(form.from).uppercased(); f.to = tr(form.to).uppercased()
        f.crew = digits(form.crew); f.out = digits(form.out); f.off = digits(form.off); f.on = digits(form.on); f.inTime = digits(form.inTime)
        f.comments = tr(form.comments); f.duty = form.duty; f.seat = form.seat; f.approaches = 0
        for b in logBoxes {
            let v = tr(form.custom[b.id] ?? ""); if v.isEmpty { continue }
            if b.kind == "field" { f.extra[b.key] = v } else { f.override[b.key] = HOUR_SRC.contains(b.src) ? toCsvHours(v) : v }
        }
        if let id = editId { f.id = id }
        return f
    }

    private func fillForm(_ f: Flight) {
        var s = FormState()
        s.date = f.date; s.flightNumber = f.flightNumber; s.tail = f.tail; s.from = f.from; s.to = f.to
        s.crew = f.crew; s.out = f.out; s.off = f.off; s.on = f.on; s.inTime = f.inTime; s.comments = f.comments
        s.duty = f.duty.isEmpty ? "PF" : f.duty; s.seat = f.seat.isEmpty ? cfg.seat : f.seat
        let isNew = f.id.isEmpty
        for b in logBoxes {
            if b.kind == "field" { s.custom[b.id] = isNew ? b.def : (f.extra[b.key] ?? "") }
            else if let o = f.override[b.key] { s.custom[b.id] = HOUR_SRC.contains(b.src) ? showHours(o, cfg.timeFmt) : o }
            else { s.custom[b.id] = "" }
        }
        form = s
    }

    func newFlight(keepDate: Bool) {
        editId = nil; scannedTrip = nil
        var f = Flight(); f.date = keepDate && !form.date.isEmpty ? form.date : todayIso(); f.duty = "PF"; f.seat = cfg.seat
        fillForm(f)
        thumb = nil; scanMsg = nil; scanTiming = nil; showDelConfirm = false
    }

    func editFlight(_ id: String) {
        guard let f = flights.first(where: { $0.id == id }) else { return }
        editId = id; scannedTrip = nil
        fillForm(f)
        thumb = nil; scanMsg = nil; scanTiming = nil; showDelConfirm = false
        show(.log)
    }

    var editingFlight: Flight? { editId.flatMap { id in flights.first { $0.id == id } } }

    func validate(_ f: Flight, _ r: Calc) -> String? {
        if f.date.isEmpty { return "Pick the date." }
        if !r.ok { return "Missing " + r.missing.joined(separator: ", ") + "." }
        if r.blockMin <= 0 || r.blockMin > 20 * 60 { return "Block time looks wrong. Check OUT and IN." }
        if r.airMin <= 0 || r.airMin > r.blockMin { return "Air time looks wrong. Check OFF and ON." }
        if f.tail.isEmpty { return "Add the aircraft registration." }
        return nil
    }

    func saveFlight() {
        let f = readForm(), r = compute(f)
        if let err = validate(f, r) { toast(err); return }
        let rand = String(UUID().uuidString.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(4))
        let id = editId ?? "\(f.date)_\(f.flightNumber.isEmpty ? "x" : f.flightNumber)_\(f.out)_\(rand)"
        let wasEdit = editId != nil
        let offline = offlineNow
        enqueue(OutOp(method: "PUT", path: "api/flights/" + Self.enc(id), body: try? JSONSerialization.data(withJSONObject: f.putBody)))
        toast(offline ? "Saved on this iPhone · uploads when Home Assistant is reachable" : (wasEdit ? "Flight updated" : "Flight saved"))
        newFlight(keepDate: true)
        if wasEdit { show(.list) }
    }

    func deleteFlight() {
        guard let id = editId else { return }
        enqueue(OutOp(method: "DELETE", path: "api/flights/" + Self.enc(id), body: nil))
        toast("Flight deleted")
        newFlight(keepDate: false)
        show(.list)
    }

    func markImported() {
        let n = flights.filter { !$0.imported }.count
        enqueue(OutOp(method: "POST", path: "api/flights/mark-imported", body: nil))
        toast("\(n) marked imported")
    }

    static func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    func show(_ t: AppTab) {
        tab = t; night = false; scrollToken += 1
    }
    func openNight() { night = true; scrollToken += 1 }

    // MARK: - Scan (Gemini runs on the add-on)

    func scan(_ image: UIImage) async {
        thumb = image
        let method = ScanMethod.current
        if loaded && !scanConfigured {
            scanMsg = ScanMsg(kind: .warn, text: "Add gemini_api_key in the add-on Configuration tab to scan. You can type the times in below.")
            return
        }
        scanMsg = ScanMsg(kind: .plain, text: "Reading the ACARS page…")
        scanTiming = nil
        let t0 = Date()
        let px = Int(max(image.size.width * image.scale, image.size.height * image.scale))
        var steps: [String] = []
        var t = Date()
        func lap(_ name: String, _ extra: String = "") { steps.append(String(format: "%@ %.1f s", name, Date().timeIntervalSince(t)) + extra); t = Date() }
        let mc = MetricsCatcher()
        // Timer for debugging: each step and the total, shown under the scan message.
        func timing(_ ok: Bool) {
            var parts = steps
            if let sp = mc.split { parts.append(String(format: "upload %.1f s", sp.upload)); parts.append(String(format: "Gemini %.1f s", sp.server)) }
            parts.append(String(format: "total %.1f s", Date().timeIntervalSince(t0)) + (ok ? "" : " (failed)"))
            scanTiming = method.title + ": " + parts.joined(separator: " · ")
        }
        do {
            let small = method == .geminiSmall
            let jpeg = await Task.detached(priority: .userInitiated) {
                small ? smallGrayJPEG(image) : downscale(image, 1600).jpegData(compressionQuality: 0.88)
            }.value
            guard let jpeg else { scanMsg = ScanMsg(kind: .bad, text: "The scan did not finish. Try again, or type the times in."); return }
            lap("Resize", " (\(px) px → \(small ? 1024 : 1600), \(ByteCountFormatter.string(fromByteCount: Int64(jpeg.count), countStyle: .file)))")
            let d = try await api.call("POST", "api/scan", body: jpeg, contentType: "image/jpeg", timeout: 120, metrics: mc)
            timing(true)
            func clean(_ v: Any?, digits: Bool) -> String {
                guard let v, !(v is NSNull) else { return "" }
                let s = jstr(v).replacingOccurrences(of: "Ø", with: "0").uppercased()
                return s.filter { $0.isASCII && (digits ? $0.isNumber : ($0.isNumber || $0.isLetter)) }
            }
            var filled = 0
            func put(_ v: String, _ kp: WritableKeyPath<FormState, String>) { if !v.isEmpty { form[keyPath: kp] = v; filled += 1 } }
            put(clean(d["flightNumber"], digits: true), \.flightNumber)
            put(String(clean(d["from"], digits: false).prefix(4)), \.from)
            put(String(clean(d["to"], digits: false).prefix(4)), \.to)
            put(clean(d["crew"], digits: true), \.crew)
            put(clean(d["out"], digits: true), \.out)
            put(clean(d["off"], digits: true), \.off)
            put(clean(d["on"], digits: true), \.on)
            put(clean(d["in"], digits: true), \.inTime)
            let tripS = jstr(d["trip"]).replacingOccurrences(of: "Ø", with: "0")
            scannedTrip = nil
            if let m = tripS.range(of: #"^(\d{1,2}):?(\d{2})$"#, options: .regularExpression), m.lowerBound == tripS.startIndex {
                let ds = tripS.filter(\.isNumber)
                if let h = Int(ds.dropLast(2)), let mi = Int(ds.suffix(2)) { scannedTrip = h * 60 + mi }
            }
            let notes = jstr(d["notes"])
            if filled == 0 {
                scanMsg = ScanMsg(kind: .bad, text: notes.isEmpty ? "No OOOI values found in that photo." : "No OOOI values found: \(notes)")
                return
            }
            let r = compute(readForm())
            var trip: Int?
            if let t = r.t, let i = t.inT { trip = Int(jsRound((i - (t.crew ?? t.out)) / 60000)) }
            let tripOk = trip != nil && scannedTrip == trip
            if tripOk && jstr(d["confidence"]) != "low" {
                scanMsg = ScanMsg(kind: .good, text: "Read the page. CREW→IN matches the TRIP time, so the times check out. Add the registration and set PF or PM.")
            } else {
                scanMsg = ScanMsg(kind: .warn, text: (scannedTrip != nil && trip != nil && !tripOk ? "CREW→IN does not match the TRIP time on the page. " : "")
                                  + "Check every value against the screen before saving." + (notes.isEmpty ? "" : " " + notes))
            }
            if form.tail.isEmpty { focusRequest = .tail }
        } catch {
            timing(false)
            scanMsg = ScanMsg(kind: .bad, text: (error as? APIError)?.message ?? "The scan did not finish. Try again, or type the times in.")
        }
    }

    // MARK: - Flights tab

    func syncDrive() async {
        if !drive.connected { show(.set); toast("Connect Google first."); return }
        syncingNow = true
        do { try await api.call("POST", "api/drive/sync", timeout: 120); toast("Drive files updated") } catch { toast(error.localizedDescription) }
        syncingNow = false
        await refresh()
    }

    func saveCsv() async {
        let name = "MyFlightbook Import \(todayIso()).csv"
        var data: Data?
        if outbox.isEmpty, let res = try? await api.raw("GET", "api/csv/pending"), res.1.statusCode == 200 { data = res.0 }
        if data == nil { data = Data(buildCsv(flights.filter { !$0.imported }, cfg).utf8) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data!.write(to: url, options: .atomic); shareFile = ShareItem(url: url) }
        catch { toast("Could not get the CSV. It is also in /share/oooi_logger.") }
    }

    // MARK: - Settings

    func saveSettings(seat: String, anonTail: String, model: String) {
        let t = anonTail.trimmingCharacters(in: .whitespaces), m = model.trimmingCharacters(in: .whitespaces)
        enqueue(OutOp(method: "PUT", path: "api/settings", body: try? JSONSerialization.data(withJSONObject: ["seat": seat, "anon_tail": t.isEmpty ? "#002377" : t, "model": m.isEmpty ? "B737" : m])))
        if editId == nil { form.seat = seat }
        toast("Settings saved")
    }

    func setTimeFmt(_ v: String) {
        enqueue(OutOp(method: "PUT", path: "api/settings", body: try? JSONSerialization.data(withJSONObject: ["time_fmt": v])))
    }

    func saveColumns(off: [String], extra: [CsvExtra], show: [String]) async -> Bool {
        let body: JSON = ["csv_names": [String: String](), "csv_off": off, "csv_extra": extra.map(\.json), "csv_show": show]
        if offlineNow {
            enqueue(OutOp(method: "PUT", path: "api/settings", body: try? JSONSerialization.data(withJSONObject: body)))
            toast("CSV columns saved on this iPhone · uploads when Home Assistant is reachable")
            return true
        }
        do {
            try await api.call("PUT", "api/settings", json: body)
            await refresh(); toast("CSV columns saved"); watchSync(); return true
        } catch let e as APIError where e.offline {
            enqueue(OutOp(method: "PUT", path: "api/settings", body: try? JSONSerialization.data(withJSONObject: body)))
            toast("CSV columns saved on this iPhone · uploads when Home Assistant is reachable"); return true
        } catch { toast(error.localizedDescription); return false }
    }

    func connectServer(url: String, password: String) async {
        let u = API.normalize(url)
        guard !u.isEmpty, URL(string: u) != nil else { toast("Enter the address, for example http://homeassistant:8199"); return }
        let changed = u != api.baseString
        api.baseString = u
        if changed { api.token = "" }
        conn = .connecting
        do {
            try await api.login(password: password)
            await refresh()
            if conn == .ok { toast("Connected to Home Assistant") }
            else if conn == .needsLogin { toast("Home Assistant wants the app password.") }
            else { toast("Cannot reach Home Assistant at that address.") }
        } catch {
            conn = (error as? APIError)?.status == 401 ? .needsLogin : .offline
            toast(error.localizedDescription)
        }
    }

    func connectGoogle() async {
        do {
            try await api.call("POST", "api/drive/connect")
            await refresh()
            pollTask?.cancel()
            pollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if Task.isCancelled { return }
                    await refresh()
                    if drive.pending == nil || drive.pending?.error != nil {
                        if drive.connected && drive.pending == nil { toast("Google Drive connected"); watchSync() }
                        return
                    }
                }
            }
        } catch { toast(error.localizedDescription) }
    }
    func cancelGoogle() async {
        pollTask?.cancel()
        _ = try? await api.call("POST", "api/drive/cancel")
        await refresh()
    }
    func disconnectGoogle() async {
        do { try await api.call("POST", "api/drive/disconnect"); await refresh(); toast("Disconnected from Google") } catch { toast(error.localizedDescription) }
    }

    func updateAirports() async -> Bool {
        do {
            let j = try await api.call("POST", "api/airports/update", timeout: 180)
            toast("Airport database updated: \(fmtNum(Int(jnum(j["count"])))) airports")
            await refresh()
            return true
        } catch { toast(error.localizedDescription); return false }
    }

    /// Use Home Assistant's airport list when it has been updated there.
    private func syncAirports() async {
        let cached = Self.file("airports.js")
        let have = UserDefaults.standard.string(forKey: "airportsUpdated")
        if airports.source == "updated", let upd = airports.updated, have != upd {
            guard let res = try? await api.raw("GET", "js/airports.js", timeout: 60), res.1.statusCode == 200,
                  let s = String(data: res.0, encoding: .utf8) else { return }
            let data = res.0
            let ok = await Task.detached { Airports.shared.load(js: s) }.value
            if ok {
                try? data.write(to: cached, options: .atomic)
                UserDefaults.standard.set(upd, forKey: "airportsUpdated")
                apVersion += 1
            }
        } else if airports.source == "bundled" && have != nil {
            UserDefaults.standard.removeObject(forKey: "airportsUpdated")
            try? FileManager.default.removeItem(at: cached)
            loadAirports()
        }
    }

    // MARK: - History (imported MyFlightbook logbook)

    var histCacheKey: String? {
        guard let h = historyInfo else { return nil }
        return "\(h.importedAt)|\(airports.updated ?? "")|\(airports.count)"
    }

    private func useHistory(_ key: String, _ entries: [LogEntry], _ unknown: Int) {
        hist = entries; histKey = key; unknownN = unknown
    }

    nonisolated private static func parseHistory(_ data: Data) -> ([LogEntry], Int)? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return nil }
        return (jarr(j["entries"]).map { LogEntry(json: jdict($0)) }, Int(jnum(j["unknown_airport_count"])))
    }

    private func loadCachedHistory() async {
        guard let key = histCacheKey, histKey != key,
              UserDefaults.standard.string(forKey: "historyKey") == key,
              let data = try? Data(contentsOf: Self.file("history.json")) else { return }
        if let res = await Task.detached(operation: { AppModel.parseHistory(data) }).value { useHistory(key, res.0, res.1) }
    }

    func loadHistory() async {
        guard let key = histCacheKey else { hist = []; histKey = nil; unknownN = 0; return }
        if histKey == key { return }
        if UserDefaults.standard.string(forKey: "historyKey") == key { await loadCachedHistory(); if histKey == key { return } }
        guard let res = try? await api.raw("GET", "api/history", timeout: 90), res.1.statusCode == 200 else { return }
        let data = res.0
        if let parsed = await Task.detached(operation: { AppModel.parseHistory(data) }).value {
            useHistory(key, parsed.0, parsed.1)
            try? data.write(to: Self.file("history.json"), options: .atomic)
            UserDefaults.standard.set(key, forKey: "historyKey")
        }
    }

    func importHistory(_ data: Data, name: String) async -> Bool {
        do {
            let j = try await api.call("POST", "api/history/import", body: data, contentType: "text/csv",
                                       headers: ["X-File-Name": Self.enc(name)], timeout: 180)
            histKey = nil
            toast("Imported \(fmtNum(Int(jnum(jdict(j["history"])["flights"])))) flights")
            await refresh()
            return true
        } catch { toast(error.localizedDescription); return false }
    }
    func removeHistory() async {
        do { try await api.call("POST", "api/history/delete"); histKey = nil; await refresh(); toast("Imported history removed") }
        catch { toast(error.localizedDescription) }
    }

    // MARK: - Logbook

    var entries: [LogEntry] { allEntries(hist: hist, app: appEntries(flights, cfg)) }

    /// The Stats period as search filters, so a tap on a top route searches the same period.
    func periodFilter() -> [String: String] {
        let p = period
        if p.count == 4, Int(p) != nil { return ["year": p] }
        if p == "12m" || p == "90d" { return ["since": addDays(todayIso(), p == "12m" ? -364 : -89)] }
        return [:]
    }
    func openFind(st: Set<String> = [], f: [String: String] = [:]) {
        var s = FindState(); s.st = st; s.f = periodFilter().merging(f) { _, b in b }
        find = s
        findMoreOpen = s.nFilters > 0
        statsView = "search"
        scrollToken += 1
    }
}

struct ShareItem: Identifiable { let url: URL; var id: String { url.path } }

func parseISO(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
}

func downscale(_ img: UIImage, _ maxSide: CGFloat) -> UIImage {
    let w = img.size.width * img.scale, h = img.size.height * img.scale
    let k = min(1, maxSide / max(w, h))
    let size = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
    let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = true
    return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
}
