import SwiftUI
import PhotosUI

struct LogView: View {
    @EnvironmentObject var m: AppModel
    @FocusState private var focus: Focus?
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var showDate = false

    private var order: [Focus] {
        [.flightNumber, .tail, .from, .to, .crew, .out, .off, .on, .inTime, .comments] + m.logBoxes.map { .custom($0.id) }
    }

    var body: some View {
        let f = m.readForm()
        let r = compute(f)
        let _ = m.apVersion
        VStack(alignment: .leading, spacing: 16) {
            if m.editId != nil, let ef = m.editingFlight { editBanner(ef) }
            scanCard
            formCard(f, r)
            autoCard(f, r)
            if m.showDelConfirm {
                ConfirmBox(text: "Delete this flight? It is removed here and from your Drive files.", yes: "Delete flight", no: "Keep it",
                           onYes: { m.deleteFlight() }, onNo: { m.showDelConfirm = false })
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(index == nil || index == order.count - 1)
                Spacer()
                Button("Done") { focus = nil }.font(F.body(17, 600))
            }
        }
        .onChange(of: m.focusRequest) { _, v in if let v { focus = v; m.focusRequest = nil } }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in Task { await m.scan(img) } }.ignoresSafeArea()
        }
        .photosPicker(isPresented: $showLibrary, selection: $libraryItem, matching: .images)
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { await m.scan(img) }
                libraryItem = nil
            }
        }
        .sheet(isPresented: $showDate) { DateSheet(iso: $m.form.date, allowClear: false) }
    }

    private var index: Int? { focus.flatMap { order.firstIndex(of: $0) } }
    private func move(_ d: Int) {
        guard let i = index else { return }
        let j = i + d
        if j >= 0 && j < order.count { focus = order[j] }
    }

    // MARK: Cards

    private func editBanner(_ f: Flight) -> some View {
        Card {
            HStack {
                (Text("Editing ").font(F.body(16, 600)) + Text("\(f.date) \(f.from)–\(f.to)").font(F.mono(16)))
                    .foregroundStyle(T.ink)
                Spacer()
                Button("New flight") { m.newFlight(keepDate: false) }.buttonStyle(BtnStyle(block: false))
            }
        }
    }

    private var scanCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true } else { showLibrary = true }
                } label: { Text("Scan OOOI page") }
                .buttonStyle(BtnStyle(kind: .primary, size: 19, vpad: 18, hpad: 18))
                .contextMenu {
                    Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                    Button { showLibrary = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                }
                Text("Take a photo of the ACARS-PREVIOUS OOOI page. Gemini reads the flight number, airports and times. Check them before saving.")
                    .font(F.body(14)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let t = m.thumb {
                Image(uiImage: t).resizable().scaledToFit().frame(maxHeight: 120).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let msg = m.scanMsg { MsgBox(kind: msg.kind, text: msg.text) }
        }
    }

    private func apLabel(_ code: String) -> String {
        guard code.count >= 4 else { return "" }
        if let a = AP[code] { return String(format: "%.2f°, %.2f°", a.lat, a.lon) }
        return "Unknown airport. Use the 4-letter ICAO code."
    }

    private func formCard(_ f: Flight, _ r: Calc) -> some View {
        Card {
            field("Date (local at departure)") {
                Button { focus = nil; showDate = true } label: {
                    Text(fmtDate(m.form.date)).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).inputChrome()
                }.buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 12) {
                field("Flight") {
                    TextField("", text: $m.form.flightNumber, prompt: prompt("1234"))
                        .keyboardType(.numberPad).focused($focus, equals: .flightNumber).inputChrome(mono: true)
                }
                field("Registration") {
                    TextField("", text: upper($m.form.tail), prompt: prompt("N12345"))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
                        .focused($focus, equals: .tail).inputChrome(mono: true)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                field("Dep", note: apLabel(f.from)) {
                    TextField("", text: upper($m.form.from, max: 4), prompt: prompt("ICAO"))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
                        .focused($focus, equals: .from).inputChrome(mono: true)
                }
                field("Des", note: apLabel(f.to)) {
                    TextField("", text: upper($m.form.to, max: 4), prompt: prompt("ICAO"))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
                        .focused($focus, equals: .to).inputChrome(mono: true)
                }
            }
            cdu(f, r)
            VStack(alignment: .leading, spacing: 5) {
                LabelText("Duty")
                Seg(options: [SegOption(v: "PF", title: "PF", small: "Logs takeoff + landing"), SegOption(v: "PM", title: "PM", small: "No takeoff or landing")],
                    value: m.form.duty) { m.form.duty = $0 }
            }
            VStack(alignment: .leading, spacing: 5) {
                LabelText("Time logged as")
                Seg(options: [SegOption(v: "PIC", title: "PIC"), SegOption(v: "SIC", title: "SIC")], value: m.form.seat) { m.form.seat = $0 }
            }
            field("Comments") {
                TextField("", text: $m.form.comments, prompt: prompt("Optional"), axis: .vertical)
                    .lineLimit(2...6).focused($focus, equals: .comments).inputChrome()
            }
            customFields(f)
        }
    }

    private func field<C: View>(_ label: String, note: String = "", @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LabelText(label)
            c()
            if !note.isEmpty { Text(note).font(F.body(13)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func upper(_ b: Binding<String>, max: Int = 0) -> Binding<String> {
        Binding(get: { b.wrappedValue }, set: { v in
            var s = v.uppercased()
            if max > 0 && s.count > max { s = String(s.prefix(max)) }
            b.wrappedValue = s
        })
    }

    // MARK: CDU panel

    private func cdu(_ f: Flight, _ r: Calc) -> some View {
        let t = r.t
        let block: Int? = t.flatMap { t in t.inT.map { Int(jsRound(($0 - t.out) / 60000)) } }
        let air: Int? = t.flatMap { t in (t.on != nil && t.off != nil) ? Int(jsRound((t.on! - t.off!) / 60000)) : nil }
        let trip: Int? = t.flatMap { t in t.inT.map { Int(jsRound(($0 - (t.crew ?? t.out)) / 60000)) } }
        let cols = isNarrow ? 3 : 5
        let tripView: Text = {
            if let trip, let st = m.scannedTrip {
                return st == trip ? Text("TRIP \(fmtHM(trip)) ✓ MATCHES ACARS").foregroundStyle(T.cduOk)
                    : Text("TRIP \(fmtHM(trip)) ≠ ACARS \(fmtHM(st))").foregroundStyle(T.cduNo)
            }
            return Text("TRIP \(fmtHM(trip))")
        }()
        let blockText = Text("BLOCK \(fmtHM(block))  AIR \(fmtHM(air))")
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OOOI · UTC"); Spacer(); Text("\(f.from.isEmpty ? "----" : f.from)/\(f.to.isEmpty ? "----" : f.to)")
            }.font(F.mono(13, 600)).tracking(0.78).foregroundStyle(T.cduInk)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8, alignment: .leading), count: cols), alignment: .leading, spacing: 8) {
                cduField("CREW", $m.form.crew, .crew, next: .out)
                cduField("OUT", $m.form.out, .out, next: .off)
                cduField("OFF", $m.form.off, .off, next: .on)
                cduField("ON", $m.form.on, .on, next: .inTime)
                cduField("IN", $m.form.inTime, .inTime, next: nil)
            }
            ViewThatFits(in: .horizontal) {
                HStack { tripView; Spacer(minLength: 8); blockText }
                VStack(alignment: .leading, spacing: 4) { tripView; blockText }
            }.font(F.mono(13, 500)).foregroundStyle(T.cduFoot)
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
        .background(T.cdu)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.cduLine, lineWidth: 1))
    }

    private func cduField(_ label: String, _ b: Binding<String>, _ me: Focus, next: Focus?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(F.mono(12, 600)).tracking(0.96).foregroundStyle(T.cduLabel)
            TextField("", text: Binding(get: { b.wrappedValue }, set: { v in
                let old = b.wrappedValue
                let s = String(v.filter { $0.isASCII && $0.isNumber }.prefix(4))
                b.wrappedValue = s
                // Typing the 4th digit moves on to the next time.
                if s.count == 4 && old.count == 3, let next { DispatchQueue.main.async { focus = next } }
            }), prompt: prompt("----", T.cduPlaceholder))
            .keyboardType(.numberPad)
            .focused($focus, equals: me)
            .font(F.mono(isNarrow ? 19 : 20, 600)).tracking(0.8)
            .foregroundStyle(T.cduInk).tint(T.cduLabel)
            .padding(.top, 4).padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(focus == me ? T.cduLabel : T.cduLine).frame(height: 1) }
        }
    }

    // MARK: Custom boxes under Comments

    @ViewBuilder private func customFields(_ f: Flight) -> some View {
        let boxes = m.logBoxes
        if !boxes.isEmpty {
            let full = csvValues(f, m.cfg)
            let vals = full ?? ["Tail Number": m.cfg.anonTail, "Model": m.cfg.model]
            LazyVGrid(columns: [GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top), GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(boxes) { b in
                    let v = m.form.custom[b.id] ?? ""
                    let edited = b.kind == "ov" && !v.trimmingCharacters(in: .whitespaces).isEmpty
                    field(b.label) {
                        TextField("", text: Binding(get: { m.form.custom[b.id] ?? "" }, set: { m.form.custom[b.id] = $0 }),
                                  prompt: prompt(placeholder(b, vals, full != nil)))
                            .autocorrectionDisabled()
                            .focused($focus, equals: .custom(b.id))
                            .inputChrome(mono: b.kind == "ov", highlight: edited)
                    }
                }
            }
        }
    }

    /// Edit boxes show the value that will be logged automatically as grey placeholder text.
    private func placeholder(_ b: LogBox, _ vals: [String: String], _ full: Bool) -> String {
        if b.kind == "field" { return b.def.isEmpty ? "Optional" : "" }
        let auto = b.isText ? b.text : vals[b.src]
        if let auto, !auto.isEmpty { return HOUR_SRC.contains(b.src) && !b.isText ? showHours(auto, m.cfg.timeFmt) : auto }
        return full ? "(blank)" : "Auto"
    }

    // MARK: Will also log automatically

    private func autoCard(_ f: Flight, _ r: Calc) -> some View {
        Card {
            HStack {
                LabelText("Will also log automatically")
                Spacer()
                LinkBtn("Show night work →") { focus = nil; m.openNight() }
            }
            if !r.ok {
                Text("Waiting for " + r.missing.joined(separator: ", ") + ".").font(F.body(14)).foregroundStyle(T.muted)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ThreeCol {
                        StatTile(value: fmtMin(r.totalMin, m.cfg.timeFmt), label: "Total · \(m.form.seat) · XC")
                        StatTile(value: fmtMin(r.nightMin, m.cfg.timeFmt), label: "Night")
                        StatTile(value: "\(r.distNm)", label: "Distance nm")
                    }
                    FlowLayout {
                        if m.form.duty == "PF" {
                            Chip(r.nightTO ? "Night takeoff" : "Day takeoff", r.nightTO ? .night : .day)
                            Chip(r.nightLdg ? "Night FS landing" : "Day FS landing", r.nightLdg ? .night : .day)
                        } else { Chip("PM · no takeoff or landing") }
                        if !f.flightNumber.isEmpty { Chip(fltNo(f.flightNumber)) }
                        if !f.tail.isEmpty { Chip(f.tail) }
                    }
                }
            }
        }
    }
}

/// A date box's picker (input type=date)
struct DateSheet: View {
    @Binding var iso: String
    var allowClear = false
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                if allowClear { Button("Clear") { iso = ""; dismiss() }.font(F.body(17, 500)) }
                Spacer()
                Button("Done") { iso = Self.iso(date); dismiss() }.font(F.body(17, 600))
            }.padding(.horizontal, 20).padding(.top, 16)
            DatePicker("", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden().padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .tint(T.accent)
        .presentationDetents([.medium, .large])
        .onAppear { if let d = Self.date(iso) { date = d } }
    }
    static func iso(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func date(_ iso: String) -> Date? {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }
}

/// The camera, straight from the Scan button.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
