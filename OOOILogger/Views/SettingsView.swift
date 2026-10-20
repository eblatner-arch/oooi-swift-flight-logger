import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @State private var seat = ""
    @State private var anonTail = ""
    @State private var model = ""
    @State private var csvOpen = false
    @State private var serverURL = API.shared.baseString
    @State private var password = ""
    @State private var connecting = false
    @State private var importing = false
    @State private var histBusy = false
    @State private var removeArmed = false
    @State private var apBusy = false
    @State private var scanMethod = ScanMethod.current

    var body: some View {
        let fmt = m.cfg.timeFmt
        VStack(alignment: .leading, spacing: 12) {
            if m.conn != .ok { serverCard }
            Card {
                VStack(alignment: .leading, spacing: 5) {
                    LabelText("Default seat time")
                    Seg(options: [SegOption(v: "PIC", title: "PIC", small: "Captain"), SegOption(v: "SIC", title: "SIC", small: "First officer")],
                        value: seat.isEmpty ? m.cfg.seat : seat) { seat = $0 }
                }
                VStack(alignment: .leading, spacing: 5) {
                    LabelText("Show hours as")
                    Seg(options: [SegOption(v: "hm", title: "3:49", small: "Hours:minutes"), SegOption(v: "dec", title: "3.8", small: "Decimal")],
                        value: fmt) { m.setTimeFmt($0) }
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        LabelText("MFB tail number")
                        TextField("", text: $anonTail).autocorrectionDisabled().textInputAutocapitalization(.characters).inputChrome(mono: true)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        LabelText("Model")
                        TextField("", text: $model).autocorrectionDisabled().textInputAutocapitalization(.characters).inputChrome(mono: true)
                    }
                }
                Small(md: "Every flight imports to one anonymous aircraft in MyFlightbook. To find its tail number: in MyFlightbook, add your type as an **Anonymous** aircraft, open it under **My Aircraft**, and copy the code under **Tail Number** (it starts with `#`). The real registration goes in the Aircraft Registration property.")
                Button("Save settings") {
                    hideKeyboard()
                    m.saveSettings(seat: seat.isEmpty ? m.cfg.seat : seat, anonTail: anonTail, model: model)
                }.buttonStyle(BtnStyle(kind: .primary))
            }
            ColumnsCard(open: $csvOpen)
            Card {
                LabelText("How it calculates")
                Small("Total time runs from CREW to IN, the same as the TRIP time on the ACARS page. Night time counts every minute from OUT to IN when the sun is more than 6° below the horizon (civil twilight) at the aircraft's position along the great-circle route. A takeoff or landing is night when it falls between one hour after sunset and one hour before sunrise at that airport (14 CFR 61.57(b)). Times are UTC; the date is the local date at departure.")
            }
            driveCard
            historyCard
            Card {
                LabelText("Airport database")
                let ap = m.airports
                Small(ap.source == "updated"
                      ? "\(fmtNum(ap.count)) airports, updated \(ap.updated.flatMap(parseISO).map { dateFormatter("MMM d, yyyy", utc: false).string(from: $0) } ?? "—"). Downloads the latest open-source airport list (airportsdata on GitHub) to your Home Assistant."
                      : "\(fmtNum(ap.count == 0 ? Airports.shared.count : ap.count)) airports from the copy built into the add-on. Update to download the latest open-source airport list (airportsdata on GitHub) to your Home Assistant.")
                Button(apBusy ? "Downloading…" : "Update airport database") {
                    apBusy = true
                    Task { _ = await m.updateAirports(); apBusy = false }
                }.buttonStyle(BtnStyle()).disabled(apBusy)
            }
            Card {
                LabelText("Photo scanning (Gemini)")
                VStack(alignment: .leading, spacing: 5) {
                    LabelText("Scan method")
                    SelectBox(options: ScanMethod.allCases.map { ($0.rawValue, $0.title) }, value: scanMethod.rawValue, block: true) {
                        if let v = ScanMethod(rawValue: $0) { scanMethod = v; ScanMethod.current = v }
                    }
                }
                Small(scanMethod.detail + " The timer under each scan shows where the time goes.")
                Small(m.scanConfigured
                      ? "Gemini is set up in the add-on Configuration (model \(m.scanModel)). Photos go from Home Assistant to Gemini; the key never reaches your phone."
                      : "Add gemini_api_key (and optionally gemini_model) in the add-on Configuration tab, then restart the add-on to turn on photo scanning.")
            }
            Card {
                LabelText("About")
                Small("Flights are stored on your Home Assistant (included in backups), written to /share/oooi_logger, and uploaded to Google Drive when connected. This app keeps a copy of everything on your iPhone, so it opens at once and works offline; flights you save without a connection upload the next time it reaches Home Assistant."
                      + " Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
            }
            if m.conn == .ok { serverCard }
        }
        .onAppear { sync() }
        .onChange(of: m.cfg) { _, _ in sync() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .data]) { res in
            guard case .success(let url) = res else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { m.toast("Couldn't read that file."); return }
            histBusy = true
            Task { _ = await m.importHistory(data, name: url.lastPathComponent); histBusy = false }
        }
    }

    private func sync() {
        seat = m.cfg.seat; anonTail = m.cfg.anonTail; model = m.cfg.model
    }

    // MARK: Home Assistant connection (this app only)

    private var serverCard: some View {
        Card {
            LabelText("Home Assistant")
            let (text, kind): (String, MsgKind) = {
                switch m.conn {
                case .notSetUp: return ("Not set up yet. Flights you save are kept on this iPhone until it can reach the add-on.", .warn)
                case .connecting: return ("Connecting…", .plain)
                case .ok: return ("Connected to \(API.shared.baseString).", .good)
                case .offline: return ("Can't reach \(API.shared.baseString) right now. Check Tailscale is on. Everything on this iPhone still works" + (m.pendingUploads > 0 ? ", and \(m.pendingUploads) change\(m.pendingUploads == 1 ? "" : "s") will upload when it's back." : "."), .bad)
                case .needsLogin: return ("The add-on wants its app password.", .bad)
                }
            }()
            MsgBox(kind: kind, text: text)
            VStack(alignment: .leading, spacing: 5) {
                LabelText("Address")
                TextField("", text: $serverURL, prompt: prompt("http://homeassistant:8199"))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().inputChrome(mono: true, size: 16)
            }
            VStack(alignment: .leading, spacing: 5) {
                LabelText("App password")
                SecureField("", text: $password, prompt: prompt(API.shared.token.isEmpty ? "Only if app_password is set" : "Saved · type to change"))
                    .inputChrome(size: 16)
            }
            Small("The add-on's own port (8199) over Tailscale: use your Home Assistant's Tailscale name or 100.x address. The password is app_password from the add-on Configuration tab, if you set one.")
            Button(connecting ? "Connecting…" : "Connect") {
                hideKeyboard(); connecting = true
                Task { await m.connectServer(url: serverURL, password: password); password = ""; serverURL = API.shared.baseString; connecting = false }
            }.buttonStyle(BtnStyle(kind: .primary)).disabled(connecting || serverURL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: Google Drive

    private var driveCard: some View {
        let d = m.drive, p = d.pending
        return Card {
            LabelText("Google Drive")
            driveInfo(d)
            if let p {
                VStack(alignment: .leading, spacing: 6) {
                    Text("On any device, open").font(F.body(13)).foregroundStyle(T.cduFoot)
                    Link((p.verificationURL.isEmpty ? "https://www.google.com/device" : p.verificationURL).replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""),
                         destination: URL(string: p.verificationURL.isEmpty ? "https://www.google.com/device" : p.verificationURL) ?? URL(string: "https://www.google.com/device")!)
                        .font(F.mono(17, 600)).foregroundStyle(T.cduLabel)
                    Text("and enter this code:").font(F.body(13)).foregroundStyle(T.cduFoot)
                    Text(p.userCode).font(F.mono(30, 600)).tracking(3.6).foregroundStyle(T.cduInk).textSelection(.enabled)
                    Button("Copy code") { UIPasteboard.general.string = p.userCode; m.toast("Code copied") }.buttonStyle(BtnStyle(block: false))
                    Text(p.error ?? "Waiting for you to approve…").font(F.body(13)).foregroundStyle(T.cduFoot)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(T.cdu).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 10) {
                if d.configured && p == nil {
                    Button(d.connected ? "Reconnect Google" : "Connect Google") { Task { await m.connectGoogle() } }.buttonStyle(BtnStyle(kind: .primary))
                }
                if d.configured && d.connected && p == nil {
                    Button("Sync now") { Task { await m.syncDrive() } }.buttonStyle(BtnStyle())
                }
            }
            if d.configured && d.connected && p == nil {
                Button("Disconnect") { Task { await m.disconnectGoogle() } }.buttonStyle(BtnStyle())
            }
            if p != nil { Button("Cancel") { Task { await m.cancelGoogle() } }.buttonStyle(BtnStyle()) }
        }
    }

    @ViewBuilder private func driveInfo(_ d: DriveInfo) -> some View {
        if !m.loaded {
            Small("Loading…")
        } else if !d.configured {
            Small("To upload to Drive, add google_client_id and google_client_secret in the add-on Configuration tab, then restart the add-on. Files are still written to /share/oooi_logger.")
        } else if d.connected {
            let synced = d.lastSync.flatMap(parseISO).map { "Last synced \(dateFormatter("M/d/yyyy, h:mm:ss a", utc: false).string(from: $0))." } ?? "Not synced yet."
            let t = Text("Connected\(d.email.isEmpty ? "" : " as " + d.email). Files go to the \"\(d.folder)\" folder in your Drive. \(synced)\(d.lastError.map { " " + $0 } ?? "")")
            if let id = d.folderID, let url = URL(string: "https://drive.google.com/drive/folders/\(AppModel.enc(id))") {
                Small(text: t + Text(" ") + Text(.init("[Open folder](\(url.absoluteString))")))
            } else { Small(text: t) }
        } else {
            Small((d.lastError.map { $0 + " " } ?? "") + "Connect your Google account once and the add-on uploads the CSVs to Drive after every change. It can only see files it creates.")
        }
    }

    // MARK: Logbook history

    private var historyCard: some View {
        let h = m.historyInfo, fmt = m.cfg.timeFmt
        return Card {
            LabelText("Logbook history")
            if let h {
                Small("\(fmtNum(h.flights)) flights\(h.simSessions > 0 ? " and \(h.simSessions) simulator sessions" : ""), \(fmtDate(h.first)) to \(fmtDate(h.last)), \(fmtH(h.totalHours, fmt)) hours. Imported \(fmtDate(String(h.importedAt.prefix(10))))\(h.file.isEmpty ? "" : " from \(h.file)").")
            } else {
                Small("No history imported. Your past flights from MyFlightbook can be added to the Stats and Map tabs.")
            }
            Small(md: "In MyFlightbook, open **Logbook → Download** and choose **CSV**, then import that file here. It's used only for Stats and Map; it is never added to your import CSVs. Importing again replaces it.")
            if let h, h.unknownCount > 0 {
                let n = h.unknownCount
                Small("\(n) airport code\(n == 1 ? " isn't" : "s aren't") in the airport list, so \(n == 1 ? "it doesn't" : "they don't") show on the map: \(h.unknownAirports.joined(separator: ", "))\(n > h.unknownAirports.count ? ", …" : ""). Tap Update airport database below to add most of them.", color: T.warn)
            }
            HStack(spacing: 10) {
                Button(histBusy ? "Importing…" : (h != nil ? "Replace with a new export" : "Import MyFlightbook logbook")) { importing = true }
                    .buttonStyle(BtnStyle(kind: .primary)).disabled(histBusy)
                if h != nil {
                    Button(removeArmed ? "Tap again to remove" : "Remove imported history") {
                        if !removeArmed { removeArmed = true; DispatchQueue.main.asyncAfter(deadline: .now() + 3) { removeArmed = false }; return }
                        removeArmed = false
                        Task { await m.removeHistory() }
                    }.buttonStyle(BtnStyle())
                }
            }
        }
    }
}

// MARK: - CSV columns editor

struct ColumnsCard: View {
    @EnvironmentObject var m: AppModel
    @Binding var open: Bool
    @State private var off: Set<String> = []
    @State private var show: Set<String> = []
    @State private var extra: [CsvExtra] = []
    @State private var dirty = false
    @State private var resetArmed = false

    var body: some View {
        Disclosure(open: $open) {
            LabelText("CSV columns")
        } content: {
            Small("These are the columns MyFlightbook's import reads, under its own names. Untick one to leave it out. Changes apply to every CSV, including the ones already in /share and Drive.")
            Small(md: "**Use** puts the column in the CSV. **Edit** adds a box for it on the Log screen, showing the automatic value in grey; type over it to change that flight's value. ✓ means it's already on the Log screen.")
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text("Use").frame(width: 40); Text("Column").frame(maxWidth: .infinity, alignment: .leading); Text("Edit").frame(width: 40)
                }.font(F.display(11, 600)).tracking(0.66).textCase(.uppercase).foregroundStyle(T.muted).padding(.bottom, 2)
                ForEach(m.csvCols, id: \.self) { c in
                    let on = !off.contains(c)
                    HStack(spacing: 8) {
                        CheckBox(on: on) { if on { off.insert(c) } else { off.remove(c) }; dirty = true }.frame(width: 40)
                        Text(c).font(F.body(15, 500)).foregroundStyle(T.ink).strikethrough(!on).opacity(on ? 1 : 0.45)
                            .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                        Group {
                            if ON_LOG_SCREEN.contains(c) { Text("✓").foregroundStyle(T.muted) }
                            else { CheckBox(on: show.contains(c), enabled: on) { if show.contains(c) { show.remove(c) } else { show.insert(c) }; dirty = true } }
                        }.frame(width: 40)
                    }
                }
            }
            LabelText("Your own columns")
            Small("Added to the end of the CSV, in the order listed here (use ↑ ↓ to reorder). Choose where each value comes from:")
            VStack(alignment: .leading, spacing: 2) {
                Small(md: "•  **Fill in on the Log screen**: a box appears under Comments for every flight.")
                Small(md: "•  **Same text on every flight**: for example *Flight Rules* = `IFR`.")
                Small(md: "•  **Copy a value**: for example *Multi-Pilot Time* copying Total Flight Time.")
            }
            VStack(spacing: 6) {
                ForEach(Array(extra.enumerated()), id: \.element.id) { i, x in extraRow(i, x) }
            }
            Button("+ Add column") {
                extra.append(CsvExtra(id: "c" + String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(8)), name: "", source: "field", text: ""))
                dirty = true
            }.buttonStyle(BtnStyle())
            HStack(spacing: 10) {
                Button("Save columns") { save(off: Array(off), extra: extra, show: Array(show)) }.buttonStyle(BtnStyle(kind: .primary))
                Button(resetArmed ? "Tap again to reset" : "Reset to defaults") {
                    if !resetArmed { resetArmed = true; DispatchQueue.main.asyncAfter(deadline: .now() + 3) { resetArmed = false }; return }
                    resetArmed = false
                    save(off: [], extra: [], show: [])
                }.buttonStyle(BtnStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: T.r))
        .overlay(RoundedRectangle(cornerRadius: T.r).stroke(T.line, lineWidth: 1))
        .onAppear { load() }
        .onChange(of: m.cfg) { _, _ in if !dirty { load() } }
    }

    private func load() {
        off = Set(m.cfg.csvOff); show = Set(m.cfg.csvShow); extra = m.cfg.csvExtra; dirty = false
    }

    private func save(off: [String], extra: [CsvExtra], show: [String]) {
        hideKeyboard()
        // keep the standard order; Edit boxes only for added columns that aren't fill-in boxes
        let offOrdered = m.csvCols.filter { off.contains($0) }
        let ids = Set(extra.filter { $0.source != "field" }.map(\.id))
        let showOrdered = m.csvCols.filter { show.contains($0) } + extra.map(\.id).filter { show.contains($0) && ids.contains($0) }
        let ex = extra.map { x -> CsvExtra in var y = x; y.name = x.name.trimmingCharacters(in: .whitespaces); return y }
        Task {
            if await m.saveColumns(off: offOrdered, extra: ex, show: showOrdered) { dirty = false; load() }
        }
    }

    private func extraRow(_ i: Int, _ x: CsvExtra) -> some View {
        let bind: (WritableKeyPath<CsvExtra, String>) -> Binding<String> = { kp in
            Binding(get: { i < extra.count ? extra[i][keyPath: kp] : "" }, set: { if i < extra.count { extra[i][keyPath: kp] = $0; dirty = true } })
        }
        let srcLabel = x.source == "field" ? "Fill in on the Log screen" : x.source == "text" ? "Same text on every flight" : x.source
        return VStack(alignment: .leading, spacing: 6) {
            TextField("", text: bind(\.name), prompt: prompt("Header name")).autocorrectionDisabled().inputChrome(size: 15, vpad: 8, hpad: 10)
            Menu {
                Button("Fill in on the Log screen") { extra[i].source = "field"; dirty = true }
                Button("Same text on every flight") { extra[i].source = "text"; dirty = true }
                Section("Copy a value") {
                    ForEach(m.csvSources, id: \.self) { c in Button(c) { extra[i].source = c; dirty = true } }
                }
            } label: {
                HStack {
                    Text(srcLabel).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(T.muted)
                }.inputChrome(size: 15, vpad: 8, hpad: 10)
            }
            if x.source == "text" || x.source == "field" {
                TextField("", text: bind(\.text), prompt: prompt(x.source == "field" ? "Pre-filled value (optional)" : "Text, e.g. IFR"))
                    .autocorrectionDisabled().inputChrome(size: 15, vpad: 8, hpad: 10)
            }
            if x.source != "field" {
                HStack(spacing: 8) {
                    CheckBox(on: show.contains(x.id), size: 20) { if show.contains(x.id) { show.remove(x.id) } else { show.insert(x.id) }; dirty = true }
                    Text("Editable on the Log screen").font(F.body(14, 500)).foregroundStyle(T.ink)
                }
            }
            HStack(spacing: 6) {
                Button("↑") { extra.swapAt(i, i - 1); dirty = true }.buttonStyle(BtnStyle(size: 15, vpad: 8, hpad: 10)).frame(width: 44).disabled(i == 0)
                Button("↓") { extra.swapAt(i, i + 1); dirty = true }.buttonStyle(BtnStyle(size: 15, vpad: 8, hpad: 10)).frame(width: 44).disabled(i == extra.count - 1)
                Button("Remove") { extra.remove(at: i); dirty = true }.buttonStyle(BtnStyle(size: 15, vpad: 8, hpad: 10))
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.line, lineWidth: 1))
    }
}
