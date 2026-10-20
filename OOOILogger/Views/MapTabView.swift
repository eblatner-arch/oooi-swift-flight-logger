import SwiftUI
import MapKit

// Map tab: every airport and route you've flown on Apple Maps, with a 3-D globe when zoomed out,
// satellite imagery, and the same filters as Stats → Search.

struct MapAirport: Identifiable { let code: String; let coord: CLLocationCoordinate2D; let n: Int; let first: String; let last: String; var id: String { code } }
struct MapRoute: Identifiable { let key: String; let a: CLLocationCoordinate2D; let b: CLLocationCoordinate2D; let n: Int; var id: String { key } }

struct MapModel {
    var airports: [MapAirport] = []
    var routes: [MapRoute] = []
    var flights = 0
    var maxN = 1
    var maxR = 1
    var labelled: Set<String> = []

    init(_ es: [LogEntry]) {
        let d = mapData(es)
        flights = es.filter { !$0.sim }.count
        airports = d.aps.compactMap { k, x in
            AP[k].map { MapAirport(code: k, coord: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon), n: x.n, first: x.first, last: x.last) }
        }.sorted { $0.n < $1.n }             // busiest drawn last, on top
        routes = d.routes.compactMap { k, n in
            let ab = k.split(separator: "|").map(String.init)
            guard ab.count == 2, let a = AP[ab[0]], let b = AP[ab[1]] else { return nil }
            return MapRoute(key: k, a: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon), b: CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon), n: n)
        }.sorted { $0.n < $1.n }
        maxN = max(1, airports.map(\.n).max() ?? 1)
        maxR = max(1, routes.map(\.n).max() ?? 1)
        labelled = Set(airports.sorted { $0.n > $1.n }.prefix(12).map(\.code))
    }
}

enum MapLook: String, CaseIterable { case standard, satellite, hybrid
    var title: String { ["standard": "Map", "satellite": "Satellite", "hybrid": "Hybrid"][rawValue]! }
    var style: MapStyle {
        switch self {
        case .standard: return .standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll)
        case .satellite: return .imagery(elevation: .realistic)
        case .hybrid: return .hybrid(elevation: .realistic, pointsOfInterest: .excludingAll)
        }
    }
}

struct MapTabView: View {
    @EnvironmentObject var m: AppModel
    @State private var find = FindState()
    @State private var filtersOpen = false
    @State private var sel: String?
    @State private var camera: MapCameraPosition = .automatic
    @State private var look = MapLook(rawValue: UserDefaults.standard.string(forKey: "mapLook") ?? "") ?? .standard
    @State private var full = false
    @State private var lastKey = ""

    var body: some View {
        let _ = m.apVersion
        let all = m.entries
        let waiting = all.isEmpty && !m.loaded
        VStack(alignment: .leading, spacing: 12) {
            if waiting {
                Card { Text("Loading your logbook…").font(F.body(16)).foregroundStyle(T.muted).frame(maxWidth: .infinity).padding(.vertical, 28) }
            } else if all.isEmpty {
                Card {
                    EmptyBlock(title: "Nothing on the map yet", text: "Log a flight, or import your MyFlightbook logbook to see every airport and route you've flown.")
                    Button("Import MyFlightbook logbook") { m.show(.set) }.buttonStyle(BtnStyle(kind: .primary))
                }
            } else {
                content(all)
            }
        }
    }

    @ViewBuilder private func content(_ all: [LogEntry]) -> some View {
        let opts = periodOptions(all)
        let period = opts.contains { $0.0 == m.period } ? m.period : "all"
        let es = applyFind(inPeriod(all, period), find)
        let mm = MapModel(es)
        let key = "\(period)|\(find.q)|\(find.st.sorted())|\(find.f)|\(mm.airports.count)|\(m.apVersion)"
        let selAp = sel.flatMap { s in mm.airports.first { $0.code == s } }
        // Filters
        Card {
            HStack { LabelText("Period"); Spacer(); SelectBox(options: opts, value: period) { m.period = $0; sel = nil } }
            TextField("", text: $find.q, prompt: prompt("Flight, airport, tail, type, month, night, >4…"))
                .textInputAutocapitalization(.characters).autocorrectionDisabled().submitLabel(.search)
                .inputChrome(size: 16, vpad: 10, hpad: 12)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(FCHIPS, id: \.0) { k, l in
                    let on = find.st.contains(k)
                    Button { if on { find.st.remove(k) } else { find.st.insert(k) } } label: {
                        Text(l).font(F.display(14, 600)).tracking(0.56)
                            .foregroundStyle(on ? T.accentInk : T.muted)
                            .padding(.vertical, 7).padding(.horizontal, 12)
                            .background(Capsule().fill(on ? T.accent : T.surface))
                            .overlay(Capsule().stroke(on ? T.accent : T.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
            Disclosure(open: $filtersOpen, arrow: "▾") {
                Text("More filters" + (find.nFilters > 0 ? " · \(find.nFilters)" : "")).font(F.display(14, 600)).tracking(0.84).textCase(.uppercase).foregroundStyle(T.muted)
            } content: {
                filterGrid(all)
            }
            Small("\(fmtNum(mm.airports.count)) airport\(mm.airports.count == 1 ? "" : "s") · \(fmtNum(mm.routes.count)) route\(mm.routes.count == 1 ? "" : "s") · \(fmtNum(mm.flights)) flight\(mm.flights == 1 ? "" : "s")"
                  + (m.unknownN > 0 ? " · \(m.unknownN) airport code\(m.unknownN == 1 ? "" : "s") not found, so not shown" : ""))
        }
        // Map
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                FlownMap(mm: mm, sel: $sel, camera: $camera, look: look)
                    .frame(height: 440)
                    .clipShape(RoundedRectangle(cornerRadius: T.r))
                    .overlay(RoundedRectangle(cornerRadius: T.r).stroke(T.line, lineWidth: 1))
                mapButtons(mm, expand: true).padding(8)
            }
            if let a = selAp { airportInfo(a, mm, es) }
            else { Small("Tap an airport for details. Pinch out for the globe; two fingers to tilt and turn.") }
            if m.histKey == nil {
                FlowLayout(spacing: 10, lineSpacing: 4) {
                    Text("Only flights logged here are shown.").font(F.body(13)).foregroundStyle(T.muted)
                    LinkBtn("Import MyFlightbook history →") { m.show(.set) }
                }
            }
        }
        .onAppear { if lastKey != key { lastKey = key; camera = .automatic } }
        .onChange(of: key) { _, k in lastKey = k; if let s = sel, !mm.airports.contains(where: { $0.code == s }) { sel = nil }; withAnimation { camera = .automatic } }
        .fullScreenCover(isPresented: $full) {
            ZStack(alignment: .topTrailing) {
                FlownMap(mm: mm, sel: $sel, camera: $camera, look: look).ignoresSafeArea()
                VStack(alignment: .trailing, spacing: 8) {
                    Button("Done") { full = false }.buttonStyle(BtnStyle(kind: .primary, size: 15, vpad: 8, hpad: 14, block: false))
                    mapButtons(mm, expand: false)
                }.padding(.top, 8).padding(.trailing, 12)
                if let a = selAp {
                    VStack { Spacer(); airportInfo(a, mm, es).padding(12).background(T.surface).clipShape(RoundedRectangle(cornerRadius: T.r)).padding(12) }
                }
            }
        }
    }

    private func mapButtons(_ mm: MapModel, expand: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Menu {
                ForEach(MapLook.allCases, id: \.self) { l in
                    Button { look = l; UserDefaults.standard.set(l.rawValue, forKey: "mapLook") } label: {
                        if l == look { Label(l.title, systemImage: "checkmark") } else { Text(l.title) }
                    }
                }
            } label: { ctlLabel(Image(systemName: look == .standard ? "map" : "globe.americas.fill")) }
            Button { withAnimation { camera = .automatic } } label: { ctlLabel(Text("Fit").font(F.display(13, 600))) }.buttonStyle(.plain)
            Button {
                let c = mm.airports.max { $0.n < $1.n }?.coord ?? CLLocationCoordinate2D(latitude: 30, longitude: -60)
                withAnimation { camera = .camera(MapCamera(centerCoordinate: c, distance: 22_000_000)) }
            } label: { ctlLabel(Image(systemName: "globe")) }.buttonStyle(.plain)
            if expand {
                Button { full = true } label: { ctlLabel(Image(systemName: "arrow.up.left.and.arrow.down.right")) }.buttonStyle(.plain)
            }
        }
    }

    private func ctlLabel(_ v: some View) -> some View {
        v.font(.system(size: 15, weight: .semibold)).foregroundStyle(T.ink).frame(width: 40, height: 36)
            .background(T.surface.opacity(0.92)).clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.line, lineWidth: 1))
    }

    private func airportInfo(_ a: MapAirport, _ mm: MapModel, _ es: [LogEntry]) -> some View {
        let routes = mm.routes.filter { $0.key.split(separator: "|").contains(Substring(a.code)) }.sorted { $0.n > $1.n }
        let top = routes.prefix(4).map { r -> String in
            let other = r.key.split(separator: "|").first { $0 != Substring(a.code) } ?? ""
            return "\(other) \(r.n)×"
        }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(a.code) · \(fmtNum(a.n)) visit\(a.n == 1 ? "" : "s") · \(routes.count) route\(routes.count == 1 ? "" : "s")").font(F.mono(15, 600)).foregroundStyle(T.ink)
            Small("First \(fmtDate(a.first)) · last \(fmtDate(a.last))" + (top.isEmpty ? "" : "\nTop routes: \(top)"))
            LinkBtn("Show these flights →") { full = false; var f = find.f; f["ap"] = a.code; m.openFind(st: find.st, f: f); m.show(.stats) }
        }
    }

    // Same "More filters" as Stats → Search
    private func filterGrid(_ all: [LogEntry]) -> some View {
        let uniq: ((LogEntry) -> String) -> [String] = { fn in Array(Set(all.map(fn).filter { !$0.isEmpty })).sorted() }
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top), GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top)], alignment: .leading, spacing: 10) {
                pick("year", "Year", uniq { String($0.d.prefix(4)) }.reversed().map { ($0, $0) })
                pick("mo", "Month", FMON.enumerated().map { (String($0.offset + 1), $0.element) })
                txt("ap", "Airport", "MCO")
                txt("route", "Route", "EWR-FLL")
                pick("ac", "Aircraft type", uniq { $0.m }.map { ($0, $0) })
                txt("tail", "Registration", "N37560")
                pick("dow", "Day", FDOW.enumerated().map { (String($0.offset), $0.element) })
                pick("both", "Direction", [("1", "Both ways")], any: "As typed")
            }
            Button("Clear all") { find = FindState() }.buttonStyle(BtnStyle())
        }
    }
    private func ff<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(F.display(12, 600)).tracking(0.96).textCase(.uppercase).foregroundStyle(T.muted)
            c()
        }
    }
    private func pick(_ k: String, _ label: String, _ opts: [(String, String)], any: String = "Any") -> some View {
        ff(label) { SelectBox(options: [("", any)] + opts, value: find.f[k] ?? "", block: true) { find.f[k] = $0 } }
    }
    private func txt(_ k: String, _ label: String, _ ph: String) -> some View {
        ff(label) {
            TextField("", text: Binding(get: { find.f[k] ?? "" }, set: { find.f[k] = $0.trimmingCharacters(in: .whitespaces) }), prompt: prompt(ph))
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .inputChrome(size: 15, vpad: 8, hpad: 9)
        }
    }
}

/// The MapKit map: great-circle routes and airport dots sized by visits.
struct FlownMap: View {
    let mm: MapModel
    @Binding var sel: String?
    @Binding var camera: MapCameraPosition
    let look: MapLook

    var body: some View {
        Map(position: $camera, interactionModes: .all) {
            ForEach(mm.routes) { r in
                let f = sqrt(Double(r.n) / Double(mm.maxR))
                MapPolyline(coordinates: [r.a, r.b], contourStyle: .geodesic)
                    .stroke(T.bar.opacity(0.4 + 0.5 * f), style: StrokeStyle(lineWidth: 1.5 + 3 * f, lineCap: .round))
            }
            ForEach(mm.airports) { a in
                let r = 3.5 + 6 * sqrt(Double(a.n) / Double(mm.maxN))
                let on = a.code == sel
                Annotation("", coordinate: a.coord, anchor: .center) {
                    Circle().fill(on ? T.accent : Color.white)
                        .frame(width: r * 2, height: r * 2)
                        .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 1.5))
                        .overlay(alignment: .leading) {
                            if on || mm.labelled.contains(a.code) {
                                Text(a.code).font(F.mono(11, 600)).foregroundStyle(.white)
                                    .shadow(color: .black, radius: 1.5).shadow(color: .black, radius: 1.5)
                                    .fixedSize().offset(x: r * 2 + 3)
                            }
                        }
                        .frame(width: 30, height: 30)       // bigger tap target
                        .contentShape(Rectangle())
                        .onTapGesture { sel = on ? nil : a.code }
                }
            }
        }
        .mapStyle(look.style)
        .mapControls { MapCompass(); MapScaleView(); MapPitchToggle() }
        .environment(\.colorScheme, .dark)
    }
}
