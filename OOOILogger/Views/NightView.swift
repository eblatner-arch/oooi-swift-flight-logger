import SwiftUI

// Night work (night.js): how the night time, takeoff and landing were worked out.

struct Sample { let m: Double; let lat: Double; let lon: Double; let alt: Double }

func trackSamples(_ t: Times, _ a: LatLon, _ b: LatLon) -> [Sample] {
    guard let off = t.off, let on = t.on, let inT = t.inT else { return [] }
    var out: [Sample] = []
    let span = on - off
    var s = t.out
    while s < inT {
        let m = s + 30000
        let f = span > 0 ? min(max((m - off) / span, 0), 1) : 0
        let p = gcPoint(a, b, f)
        out.append(Sample(m: m, lat: p.lat, lon: p.lon, alt: sunAlt(m, p.lat, p.lon)))
        s += 60000
    }
    return out
}

struct Crossings { var setBefore: Double?, riseBefore: Double?, setAfter: Double?, riseAfter: Double? }
/// Sunrise/sunset crossings (sun's upper edge, −0.833°) within 30 h either side.
func crossings(_ ms: Double, _ ap: LatLon) -> Crossings {
    let H0 = -0.833, step = 60000.0
    var res = Crossings()
    var prev = sunAlt(ms, ap.lat, ap.lon)
    var s = ms - step
    while s > ms - 30 * 3600000 {
        let v = sunAlt(s, ap.lat, ap.lon)
        if v >= H0 && prev < H0 && res.setBefore == nil { res.setBefore = s }
        if v < H0 && prev >= H0 && res.riseBefore == nil { res.riseBefore = s }
        if res.setBefore != nil && res.riseBefore != nil { break }
        prev = v; s -= step
    }
    prev = sunAlt(ms, ap.lat, ap.lon)
    s = ms + step
    while s < ms + 30 * 3600000 {
        let v = sunAlt(s, ap.lat, ap.lon)
        if prev >= H0 && v < H0 && res.setAfter == nil { res.setAfter = s }
        if prev < H0 && v >= H0 && res.riseAfter == nil { res.riseAfter = s }
        if res.setAfter != nil && res.riseAfter != nil { break }
        prev = v; s += step
    }
    return res
}

func sunColor(_ v: Double) -> Color { v < -6 ? T.night : v < -0.833 ? T.twi : T.day }

struct NightView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        let f = m.readForm(), r = compute(f)
        let _ = m.apVersion
        VStack(alignment: .leading, spacing: 12) {
            LinkBtn("← Back to Log") { m.night = false; m.scrollToken += 1 }
            if !r.ok {
                Card { EmptyBlock(title: "No flight to show", text: "Enter or scan a flight on the Log tab, or tap a saved flight in Flights. This tab shows how its night time, takeoff and landing were worked out.") }
            } else if let t = r.t, let a = AP[f.from], let b = AP[f.to] {
                content(f, r, t, a.p, b.p)
            }
        }
    }

    @ViewBuilder private func content(_ f: Flight, _ r: Calc, _ t: Times, _ a: LatLon, _ b: LatLon) -> some View {
        let smp = trackSamples(t, a, b)
        let fmt = m.cfg.timeFmt
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("\(f.from)–\(f.to)\(f.flightNumber.isEmpty ? "" : " · " + fltNo(f.flightNumber))").font(F.mono(20, 600)).foregroundStyle(T.ink)
                Spacer()
                Text(fmtDate(f.date, .weekdayDay) + ", " + String(f.date.prefix(4))).font(F.body(13)).foregroundStyle(T.muted)
            }
            ThreeCol {
                StatTile(value: fmtMin(r.nightMin, fmt), label: "Night")
                StatTile(value: fmtMin(r.blockMin, fmt), label: "Block, OUT→IN")
                StatTile(value: "\(r.distNm)", label: "Great circle nm")
            }
            Small(segText(smp, t, f))
        }
        Card {
            LabelText("Sun elevation at the aircraft")
            SunChart(smp: smp, t: t).aspectRatio(340 / 190, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
            Small("Night is logged for every minute the sun is below −6° (shaded), from OUT to IN. Before OFF the aircraft is at the departure airport, after ON at the arrival airport, and in between it moves along the great-circle route.")
        }
        Card {
            LabelText("Route")
            RouteMap(smp: smp, t: t, a: a, b: b, from: f.from, to: f.to)
            HStack(spacing: 6) { Chip("Day", .keyDay); Chip("Civil twilight", .keyTwi); Chip("Night", .keyNight) }
        }
        Card {
            LabelText("Takeoff and landing · 14 CFR 61.57(b)")
            VStack(spacing: 12) {
                opCard("Takeoff", t.off!, a, f.from, r.nightTO, f.duty)
                opCard("Landing", t.on!, b, f.to, r.nightLdg, f.duty)
            }
            Small("A takeoff or landing counts as night between one hour after sunset and one hour before sunrise at that airport. Sunset and sunrise use the sun's upper edge at the horizon (−0.833°).")
        }
    }

    private func segText(_ smp: [Sample], _ t: Times, _ f: Flight) -> String {
        var segs: [(Double, Double)] = []; var cur: (Double, Double)?
        for s in smp {
            let n = s.alt < -6
            if n && cur == nil { cur = (s.m - 30000, s.m + 30000) }
            else if n { cur!.1 = s.m + 30000 }
            else if let c = cur { segs.append(c); cur = nil }
        }
        if let c = cur { segs.append(c) }
        let phase: (Double) -> String = { ms in ms <= t.off! ? "at \(f.from)" : ms >= t.on! ? "at \(f.to)" : "en route" }
        if segs.isEmpty { return "The sun stays above −6° for the whole block, so no night time is logged." }
        return "Night " + segs.map { g in
            "\(zt(g.0)) (\(phase(g.0))) to \(zt(g.1)) (\(phase(g.1 - 1))), \(fmtHM(Int(jsRound((g.1 - g.0) / 60000))))"
        }.joined(separator: "; ") + "."
    }

    private func opCard(_ kind: String, _ ms: Double, _ ap: LatLon, _ code: String, _ isNight: Bool, _ duty: String) -> some View {
        let c = crossings(ms, ap), H = 3600000.0
        var rows: [(String, String)] = []
        let z: (Double?) -> String = { $0.map(zt) ?? "—" }
        if isNight {
            rows = [("Sunset", z(c.setBefore)), ("Night ops from", z(c.setBefore.map { $0 + H })),
                    ("Sunrise", z(c.riseAfter)), ("Night ops until", z(c.riseAfter.map { $0 - H }))]
        } else {
            let sunDown = c.setBefore != nil && (c.riseBefore == nil || c.setBefore! > c.riseBefore!)
            if !sunDown {
                rows = [("Sunrise", z(c.riseBefore)), ("Sunset", z(c.setAfter)), ("Night ops from", z(c.setAfter.map { $0 + H }))]
            } else if let sb = c.setBefore, ms < sb + H {
                rows = [("Sunset", zt(sb)), ("Night ops from", zt(sb + H) + " (after this)")]
            } else {
                rows = [("Sunrise", z(c.riseAfter)), ("Night ops until", c.riseAfter.map { zt($0 - H) + " (before this)" } ?? "—")]
            }
        }
        rows.append(("Sun at " + kind.lowercased(), String(format: "%.1f°", sunAlt(ms, ap.lat, ap.lon))))
        let note = duty == "PF" ? (isNight ? "Logged as a night \(kind.lowercased())." : "Logged as a day \(kind.lowercased()).") : "You were PM, so no \(kind.lowercased()) is logged."
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(kind) · \(code) · \(zt(ms))").font(F.display(17, 600)).tracking(0.5).foregroundStyle(T.ink)
                Spacer()
                Chip(isNight ? "Night" : "Day", isNight ? .night : .day)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(rows, id: \.0) { k, v in
                    GridRow {
                        Text(k).font(F.body(14)).foregroundStyle(T.muted)
                        Text(v).font(F.mono(14)).foregroundStyle(T.ink).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Small(note)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.line, lineWidth: 1))
    }
}

/// Sun elevation along the flight (viewBox 340×190)
struct SunChart: View {
    let smp: [Sample]
    let t: Times
    var body: some View {
        Canvas { ctx, size in
            let W = 340.0, H = 190.0, L = 34.0, R = 8.0, Tp = 22.0, B = 26.0
            let s = size.width / W
            ctx.scaleBy(x: s, y: s)
            guard let off = t.off, let on = t.on, let inT = t.inT, !smp.isEmpty else { return }
            var lo = min(-10, smp.map(\.alt).min()!), hi = max(5, smp.map(\.alt).max()!)
            lo = (lo / 5).rounded(.down) * 5; hi = (hi / 5).rounded(.up) * 5
            let x: (Double) -> Double = { L + ($0 - t.out) / (inT - t.out) * (W - L - R) }
            let y: (Double) -> Double = { Tp + (hi - $0) / (hi - lo) * (H - Tp - B) }
            ctx.fill(Path(CGRect(x: L, y: y(-6), width: W - L - R, height: y(lo) - y(-6))), with: .color(T.nightSoft))
            ctx.fill(Path(CGRect(x: L, y: y(-0.833), width: W - L - R, height: y(-6) - y(-0.833))), with: .color(T.twiSoft))
            var v = lo
            let step = hi - lo > 40 ? 10.0 : 5.0
            while v <= hi {
                var p = Path(); p.move(to: CGPoint(x: L, y: y(v))); p.addLine(to: CGPoint(x: W - R, y: y(v)))
                ctx.stroke(p, with: .color(T.line), lineWidth: 1)
                ctx.draw(Text("\(Int(v))°").font(F.mono(10)).foregroundStyle(T.muted), at: CGPoint(x: L - 5, y: y(v)), anchor: .trailing)
                v += step
            }
            var dl = Path(); dl.move(to: CGPoint(x: L, y: y(-6))); dl.addLine(to: CGPoint(x: W - R, y: y(-6)))
            ctx.stroke(dl, with: .color(T.night), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            ctx.draw(Text("−6° night").font(F.mono(10)).foregroundStyle(T.night), at: CGPoint(x: W - R - 2, y: y(-6) + 8), anchor: .trailing)
            for ms in [off, on] {
                var p = Path(); p.move(to: CGPoint(x: x(ms), y: Tp - 4)); p.addLine(to: CGPoint(x: x(ms), y: H - B))
                ctx.stroke(p, with: .color(T.muted), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            ctx.draw(Text("OFF " + zt(off)).font(F.mono(10)).foregroundStyle(T.ink), at: CGPoint(x: max(x(off), L), y: 8), anchor: .leading)
            ctx.draw(Text("ON " + zt(on)).font(F.mono(10)).foregroundStyle(T.ink), at: CGPoint(x: min(x(on), W - R), y: 8), anchor: .trailing)
            ctx.draw(Text("OUT " + zt(t.out)).font(F.mono(10)).foregroundStyle(T.muted), at: CGPoint(x: L, y: H - 12), anchor: .leading)
            ctx.draw(Text("IN " + zt(inT)).font(F.mono(10)).foregroundStyle(T.muted), at: CGPoint(x: W - R, y: H - 12), anchor: .trailing)
            // elevation line, colored by state
            var pts: [CGPoint] = []; var runCat = -1; var runCol = T.day
            let cat: (Double) -> Int = { $0 < -6 ? 0 : $0 < -0.833 ? 1 : 2 }
            func flush() {
                guard pts.count > 1 else { return }
                var p = Path(); p.addLines(pts)
                ctx.stroke(p, with: .color(runCol), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }
            for sm in smp {
                let pt = CGPoint(x: x(sm.m), y: y(sm.alt)), c = cat(sm.alt)
                if c != runCat {
                    if !pts.isEmpty { pts.append(pt); flush() }
                    pts = [pt]; runCat = c; runCol = sunColor(sm.alt)
                } else { pts.append(pt) }
            }
            flush()
        }
    }
}

/// Route map with the track colored by sun state.
struct RouteMap: View {
    let smp: [Sample]
    let t: Times
    let a: LatLon
    let b: LatLon
    let from: String
    let to: String
    @State private var landReady = Land.shared.path != nil

    static func frame(_ smp: [Sample], _ a: LatLon, _ b: LatLon) -> (k: Double, leftX: Double, top: Double, w: Double, h: Double) {
        let lons = smp.map(\.lon), lats = smp.map(\.lat)
        let minLon = lons.min() ?? min(a.lon, b.lon), maxLon = lons.max() ?? max(a.lon, b.lon)
        let minLat = lats.min() ?? min(a.lat, b.lat), maxLat = lats.max() ?? max(a.lat, b.lat)
        let k = cos((minLat + maxLat) / 2 * RAD)
        var w = (maxLon - minLon) * k, h = maxLat - minLat
        let pad = max(1.5, max(w, h) * 0.18)
        w += pad * 2; h += pad * 2
        if w / h < 1.25 { w = h * 1.25 } else if w / h > 1.8 { h = w / 1.8 }   // keep a landscape frame
        return (k, (minLon + maxLon) / 2 * k - w / 2, -(minLat + maxLat) / 2 - h / 2, w, h)
    }

    var body: some View {
        let fr = Self.frame(smp, a, b)
        let k = fr.k, leftX = fr.leftX, top = fr.top, ww = fr.w, hh = fr.h
        Canvas { ctx, size in
            let s = size.width / ww
            // view coords: x = lon*k, y = -lat
            let tf = CGAffineTransform(a: k * s, b: 0, c: 0, d: s, tx: -leftX * s, ty: -top * s)
            let px: (Double, Double) -> CGPoint = { lon, lat in CGPoint(x: (lon * k - leftX) * s, y: (-lat - top) * s) }
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(T.water))
            if landReady, let land = Land.shared.path {
                let p = Path(land).applying(tf)
                ctx.fill(p, with: .color(T.land)); ctx.stroke(p, with: .color(T.coast), lineWidth: 0.8)
            }
            // graticule every 5°
            var lon = (leftX / k / 5).rounded(.up) * 5
            while lon < (leftX + ww) / k {
                var g = Path(); g.move(to: px(lon, -top)); g.addLine(to: px(lon, -(top + hh)))
                ctx.stroke(g, with: .color(T.coast.opacity(0.6)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 4])); lon += 5
            }
            var lat = (-(top + hh) / 5).rounded(.up) * 5
            while lat < -top {
                var g = Path(); g.move(to: CGPoint(x: 0, y: (-lat - top) * s)); g.addLine(to: CGPoint(x: size.width, y: (-lat - top) * s))
                ctx.stroke(g, with: .color(T.coast.opacity(0.6)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 4])); lat += 5
            }
            // route colored by sun state
            let air = smp.filter { $0.m >= t.off! && $0.m <= t.on! }
            let pts = air.isEmpty ? smp : air
            var run = Path(); var cat = -1; var col = T.day
            let catOf: (Double) -> Int = { $0 < -6 ? 0 : $0 < -0.833 ? 1 : 2 }
            for sm in pts {
                let p = px(sm.lon, sm.lat), c = catOf(sm.alt)
                if c != cat {
                    if cat >= 0 { run.addLine(to: p); ctx.stroke(run, with: .color(col), style: StrokeStyle(lineWidth: 3.5, lineCap: .round)) }
                    run = Path(); run.move(to: p); cat = c; col = sunColor(sm.alt)
                } else { run.addLine(to: p) }
            }
            if cat >= 0 { ctx.stroke(run, with: .color(col), style: StrokeStyle(lineWidth: 3.5, lineCap: .round)) }
            // airports
            let fs = hh / 22 * s, rr = hh / 70 * s
            for (ap, code) in [(a, from), (b, to)] {
                let c = px(ap.lon, ap.lat)
                let circle = Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
                ctx.fill(circle, with: .color(T.surface)); ctx.stroke(circle, with: .color(T.ink), lineWidth: 1.5)
                let right = c.x < size.width * 0.75
                let at = CGPoint(x: c.x + (right ? rr * 1.8 : -rr * 1.8), y: c.y)
                haloText(ctx, code, size: fs, at: at, anchor: right ? .leading : .trailing, halo: T.water)
            }
        }
        .aspectRatio(ww / hh, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line, lineWidth: 1))
        .onAppear { if !landReady { Land.shared.load { landReady = true } } }
    }
}

/// Mono label with a halo (paint-order: stroke) so it reads over land and water.
func haloText(_ ctx: GraphicsContext, _ s: String, size: CGFloat, at: CGPoint, anchor: UnitPoint, halo: Color, ink: Color = T.ink) {
    let d = max(1, size * 0.14)
    let ht = ctx.resolve(Text(s).font(F.mono(size, 600)).foregroundStyle(halo))
    for (dx, dy) in [(-d, 0), (d, 0), (0, -d), (0, d), (-d * 0.7, -d * 0.7), (d * 0.7, d * 0.7), (-d * 0.7, d * 0.7), (d * 0.7, -d * 0.7)] {
        ctx.draw(ht, at: CGPoint(x: at.x + dx, y: at.y + dy), anchor: anchor)
    }
    ctx.draw(Text(s).font(F.mono(size, 600)).foregroundStyle(ink), at: at, anchor: anchor)
}
