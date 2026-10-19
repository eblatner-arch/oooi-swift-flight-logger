import SwiftUI

// Map tab (logbook.js): every airport and route, on a world that wraps east–west.

let WRAP = [-360.0, 0, 360]

struct MapTabView: View {
    @EnvironmentObject var m: AppModel
    @State private var sel: String?
    @State private var view: MapView_?
    @State private var fitKey = ""

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
        let d = mapData(inPeriod(all, period))
        let key = "\(period)|\(d.aps.count)|\(d.routes.count)|\(m.apVersion)"
        let fitted = fitView(Array(d.aps.keys))
        let v = (fitKey == key ? view : nil) ?? fitted
        let sel = (self.sel.flatMap { d.aps[$0] != nil ? $0 : nil })
        Card {
            HStack { LabelText("Period"); Spacer(); SelectBox(options: opts, value: period) { m.period = $0; self.sel = nil } }
            Small("\(fmtNum(d.aps.count)) airport\(d.aps.count == 1 ? "" : "s") · \(fmtNum(d.routes.count)) route\(d.routes.count == 1 ? "" : "s")"
                  + (m.unknownN > 0 ? " · \(m.unknownN) airport code\(m.unknownN == 1 ? "" : "s") not found, so not shown" : ""))
            ZStack(alignment: .topTrailing) {
                WorldMap(data: d, view: v, sel: sel,
                         onView: { nv in view = nv; fitKey = key },
                         onTap: { code in self.sel = code })
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line, lineWidth: 1))
                VStack(spacing: 6) {
                    ctl("+") { view = zoom(v, 1 / 1.5); fitKey = key }
                    ctl("−") { view = zoom(v, 1.5); fitKey = key }
                    ctl("Fit", size: 12) { view = fitted; fitKey = key }
                }.padding(8)
            }
            Small(info(sel, d))
            if m.histKey == nil {
                FlowLayout(spacing: 10, lineSpacing: 4) {
                    Text("Only flights logged here are shown.").font(F.body(13)).foregroundStyle(T.muted)
                    LinkBtn("Import MyFlightbook history →") { m.show(.set) }
                }
            }
        }
    }

    private func ctl(_ t: String, size: CGFloat = 18, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(F.display(size, 600)).foregroundStyle(T.ink).frame(width: 40, height: 34)
                .background(T.surface).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func info(_ code: String?, _ d: MapData) -> String {
        guard let code, let x = d.aps[code] else { return "Tap an airport for details. Drag to move, pinch or use + − to zoom." }
        let routes = d.routes.keys.filter { $0.split(separator: "|").contains(Substring(code)) }.count
        return "\(code) · \(fmtNum(x.n)) visit\(x.n == 1 ? "" : "s") · \(routes) route\(routes == 1 ? "" : "s") · first \(fmtDate(x.first)) · last \(fmtDate(x.last))"
    }
}

func zoom(_ v: MapView_, _ f: Double, _ px: Double = 0.5, _ py: Double = 0.5) -> MapView_ {
    let w = min(max(v.w * f, 0.5), 360 * v.k), h = w / v.w * v.h
    return clampView(MapView_(x: v.x + (v.w - w) * px, y: v.y + (v.h - h) * py, w: w, h: h, k: v.k))
}

struct WorldMap: View {
    let data: MapData
    let view: MapView_
    let sel: String?
    var onView: (MapView_) -> Void
    var onTap: (String?) -> Void

    @State private var dragStart: MapView_?
    @State private var pinchStart: MapView_?
    @State private var landReady = Land.shared.path != nil

    /// viewBox → pixels, like preserveAspectRatio="xMidYMid meet"
    private func xf(_ v: MapView_, _ size: CGSize) -> (s: Double, ox: Double, oy: Double) {
        let s = min(size.width / v.w, size.height / v.h)
        return (s, (size.width - v.w * s) / 2, (size.height - v.h * s) / 2)
    }

    var body: some View {
        GeometryReader { g in
            let arcs = data.routes.sorted { $0.value < $1.value }.compactMap { kv -> ([(Double, Double)], Int)? in
                let ab = kv.key.split(separator: "|").map(String.init)
                guard ab.count == 2, let a = AP[ab[0]], let b = AP[ab[1]] else { return nil }
                return (arc(a.p, b.p), kv.value)
            }
            Canvas { ctx, size in
                let v = view, k = v.k
                let (s, ox, oy) = xf(v, size)
                let P: (Double, Double) -> CGPoint = { x, y in CGPoint(x: (x - v.x) * s + ox, y: (y - v.y) * s + oy) }
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(T.water))
                if landReady, let land = Land.shared.path {
                    for o in WRAP {
                        // skip copies that are off screen
                        let x0 = (-180 + o) * k, x1 = (180 + o) * k
                        if x1 < v.x || x0 > v.x + v.w { continue }
                        let tf = CGAffineTransform(a: k * s, b: 0, c: 0, d: s, tx: (o * k - v.x) * s + ox, ty: -v.y * s + oy)
                        let p = Path(land).applying(tf)
                        ctx.fill(p, with: .color(T.land)); ctx.stroke(p, with: .color(T.coast), lineWidth: 0.8)
                    }
                }
                let maxR = Double(max(1, data.routes.values.max() ?? 1))
                for (pts, n) in arcs {
                    let w = 1 + 2.5 * sqrt(Double(n) / maxR), op = 0.35 + 0.55 * sqrt(Double(n) / maxR)
                    for o in WRAP {
                        var p = Path()
                        p.addLines(pts.map { P(($0.0 + o) * k, $0.1) })
                        ctx.stroke(p, with: .color(T.bar.opacity(op)), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                    }
                }
                let maxN = Double(max(1, data.aps.values.map { $0.n }.max() ?? 1))
                let unit = v.h / 300 * s   // one "screen pixel" at a ~300px tall map
                let ranked = data.aps.sorted { $0.value.n != $1.value.n ? $0.value.n > $1.value.n : $0.key < $1.key }
                var labelled = Set(ranked.prefix(10).map { $0.key })
                if let sel { labelled.insert(sel) }
                for o in WRAP {
                    for (code, x) in ranked.reversed() {
                        guard let a = AP[code] else { continue }
                        let c = P((a.lon + o) * k, -a.lat), r = unit * (2.5 + 5 * sqrt(Double(x.n) / maxN))
                        let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                        ctx.fill(circle, with: .color(code == sel ? T.accent : T.ink)); ctx.stroke(circle, with: .color(T.surface), lineWidth: 1.5)
                    }
                    for code in labelled {
                        guard let a = AP[code], data.aps[code] != nil else { continue }
                        let fs = unit * 11
                        let at = P((a.lon + o) * k, -a.lat)
                        haloText(ctx, code, size: fs, at: CGPoint(x: at.x + unit * 8, y: at.y), anchor: .leading, halo: T.water)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { gv in
                        let st = dragStart ?? view
                        if dragStart == nil { dragStart = view }
                        let (s, _, _) = xf(st, g.size)
                        let dx = gv.translation.width / s, dy = gv.translation.height / s
                        onView(clampView(MapView_(x: st.x - dx, y: st.y - dy, w: st.w, h: st.h, k: st.k)))
                    }
                    .onEnded { _ in dragStart = nil }
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { mg in
                            let st = pinchStart ?? view
                            if pinchStart == nil { pinchStart = view }
                            let (s, ox, oy) = xf(st, g.size)
                            let px = (mg.startLocation.x - ox) / (st.w * s), py = (mg.startLocation.y - oy) / (st.h * s)
                            onView(zoom(st, 1 / max(0.05, mg.magnification), px, py))
                        }
                        .onEnded { _ in pinchStart = nil; dragStart = nil })
            )
            .onTapGesture(coordinateSpace: .local) { loc in onTap(hit(loc, g.size)) }
        }
        .onAppear { if !landReady { Land.shared.load { landReady = true } } }
    }

    private func hit(_ loc: CGPoint, _ size: CGSize) -> String? {
        let v = view
        let (s, ox, oy) = xf(v, size)
        let unit = v.h / 300 * s
        let maxN = Double(max(1, data.aps.values.map { $0.n }.max() ?? 1))
        var best: (String, Double)?
        for (code, x) in data.aps {
            guard let a = AP[code] else { continue }
            let r = max(unit * (2.5 + 5 * sqrt(Double(x.n) / maxN)), unit * 11)
            for o in WRAP {
                let c = CGPoint(x: ((a.lon + o) * v.k - v.x) * s + ox, y: (-a.lat - v.y) * s + oy)
                let d = hypot(c.x - loc.x, c.y - loc.y)
                if d <= r && (best == nil || d < best!.1) { best = (code, d) }
            }
        }
        return best?.0
    }
}
