import SwiftUI

struct StatsView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        let _ = m.apVersion
        let all = m.entries
        let waiting = all.isEmpty && !m.loaded
        VStack(alignment: .leading, spacing: 12) {
            if waiting {
                Card { Text("Loading your logbook…").font(F.body(16)).foregroundStyle(T.muted).frame(maxWidth: .infinity).padding(.vertical, 28) }
            } else if all.isEmpty {
                Card {
                    EmptyBlock(title: "No flights yet", text: "Log a flight, or import your MyFlightbook logbook to see your totals, currency and records.")
                    Button("Import MyFlightbook logbook") { m.show(.set) }.buttonStyle(BtnStyle(kind: .primary))
                }
            } else {
                Seg(options: [SegOption(v: "overview", title: "Overview"), SegOption(v: "search", title: "Search")], value: m.statsView) { v in
                    if v == "search" && m.statsView != "search" { m.findMoreOpen = m.find.nFilters > 0 }
                    m.statsView = v
                }
                if m.statsView == "search" { SearchView(all: all) } else { Overview(all: all) }
            }
        }
    }
}

// MARK: - Overview

struct Overview: View {
    @EnvironmentObject var m: AppModel
    let all: [Entry]
    @State private var tip: String?
    @State private var tipKey: String?
    @State private var tableOpen = false

    var body: some View {
        let opts = periodOptions(all)
        let period = opts.contains { $0.0 == m.period } ? m.period : "all"
        let es = inPeriod(all, period), t = totals(es)
        let fmt = m.cfg.timeFmt
        let nApp = es.filter { $0.src == "app" }.count
        VStack(alignment: .leading, spacing: 12) {
            Card {
                LabelText("Currency")
                CurrencyBox(all: all)
            }
            Card {
                HStack { LabelText("Period"); Spacer(); SelectBox(options: opts, value: period) { m.period = $0; tip = nil } }
                Small("\(fmtNum(es.count)) entr\(es.count == 1 ? "y" : "ies")" + (m.histKey != nil ? " · \(fmtNum(es.count - nApp)) from MyFlightbook, \(fmtNum(nApp)) logged here" : " logged here"))
                ThreeCol {
                    tile(fmtH(t.total, fmt), "Total hours", [])
                    tile(fmtH(t.pic, fmt), "PIC", ["pic"])
                    tile(fmtH(t.sic, fmt), "SIC", ["sic"])
                    tile(fmtH(t.night, fmt), "Night", ["night"])
                    tile(fmtH(t.xc, fmt), "Cross-country", nil)
                    tile(fmtNum(t.flights), "Flights", [])
                    tile(fmtNum(t.l), "Landings · \(fmtNum(t.ln)) night", ["ldg"])
                    tile(fmtNum(t.airports), "Airports", nil)
                    tile(fmtNum(t.nm), "Distance nm", nil)
                }
                if t.sims > 0 { Small("Plus \(t.sims) simulator session\(t.sims == 1 ? "" : "s") (not counted as flights).") }
                if m.histKey == nil {
                    FlowLayout(spacing: 10, lineSpacing: 4) {
                        Text("Only flights logged here are counted.").font(F.body(13)).foregroundStyle(T.muted)
                        LinkBtn("Import MyFlightbook history →") { m.show(.set) }
                    }
                }
            }
            let bk = buckets(es, period)
            Card {
                LabelText(bk.byYear ? "Hours by year" : "Hours by month")
                BarChart(rows: bk.rows, fmt: fmt, selected: tipKey) { r in
                    tipKey = r.key
                    tip = "\(r.full) · \(fmtHu(r.t.total, fmt)) · \(r.t.flights) flight\(r.t.flights == 1 ? "" : "s") · \(fmtH(r.t.night, fmt)) night · \(r.t.l) ldg"
                }
                .aspectRatio(520 / 200, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if let tip { Text(tip).font(F.mono(13)).foregroundStyle(T.ink).fixedSize(horizontal: false, vertical: true) }
                VStack(alignment: .leading, spacing: 8) {
                    LinkBtn("Show as a table") { tableOpen.toggle() }
                    if tableOpen { BarTable(rows: bk.rows, byYear: bk.byYear, fmt: fmt) }
                }
            }
            topCards(es, fmt)
            Card {
                LabelText("Records")
                Records(es: es, fmt: fmt)
            }
        }
        .onChange(of: m.period) { _, _ in tip = nil; tipKey = nil }
    }

    @ViewBuilder private func tile(_ v: String, _ l: String, _ st: Set<String>?) -> some View {
        if let st {
            Button { m.openFind(st: st) } label: { StatTile(value: v, label: l).contentShape(Rectangle()) }.buttonStyle(.plain)
        } else { StatTile(value: v, label: l) }
    }

    @ViewBuilder private func topCards(_ es: [Entry], _ fmt: String) -> some View {
        let (pairs, aps, types) = Self.tops(es)
        let pf = m.periodFilter()
        Card {
            LabelText("Top routes")
            TopList(rows: pairs.prefix(8).map { k, p in
                let xy = k.split(separator: "|").map(String.init), x = xy[0], y = xy[1]
                return TopRow(name: "\(x) ⇄ \(y)", n: Double(p.n), sub: "\(fmtNum(p.n))× · \(fmtHu(p.h, fmt))",
                              note: "\(fmtNum(p.fwd)) \(x)→\(y) · \(fmtNum(p.n - p.fwd)) \(y)→\(x)",
                              go: { m.openFind(f: pf.merging(["route": "\(x)-\(y)", "both": "1"]) { _, b in b }) })
            }, empty: "No routes in this period.")
        }
        Card {
            LabelText("Top airports")
            TopList(rows: aps.prefix(8).map { k, n in
                TopRow(name: k, n: Double(n), sub: "\(fmtNum(n)) visit\(n == 1 ? "" : "s")", note: "", go: { m.openFind(f: pf.merging(["ap": k]) { _, b in b }) })
            }, empty: "No airports in this period.")
        }
        Card {
            LabelText("Aircraft types · hours")
            TopList(rows: types.prefix(6).map { k, h in
                TopRow(name: k, n: h, sub: fmtHu(h, fmt), note: "", go: { m.openFind(f: pf.merging(["ac": k]) { _, b in b }) })
            }, empty: "No aircraft in this period.")
        }
    }

    struct Pair { var n = 0; var h = 0.0; var fwd = 0 }
    static func tops(_ es: [Entry]) -> ([(String, Pair)], [(String, Int)], [(String, Double)]) {
        var pairs: [String: Pair] = [:], aps: [String: Int] = [:], types: [String: Double] = [:]
        var pOrder: [String] = [], aOrder: [String] = [], tOrder: [String] = []
        for e in es where !e.sim {
            let lg = legs(e)
            for (a, b) in lg {
                let s = [a, b].sorted(), k = "\(s[0])|\(s[1])"
                if pairs[k] == nil { pOrder.append(k) }
                var p = pairs[k] ?? Pair(); p.n += 1; if a == s[0] { p.fwd += 1 }; p.h += e.t / Double(max(1, lg.count)); pairs[k] = p
            }
            var seen = Set<String>()
            for a in e.r where !seen.contains(a) { seen.insert(a); if aps[a] == nil { aOrder.append(a) }; aps[a, default: 0] += 1 }
            if !e.m.isEmpty { if types[e.m] == nil { tOrder.append(e.m) }; types[e.m, default: 0] += e.t }
        }
        // stable sort, like Array.prototype.sort in the web app
        let P = pOrder.enumerated().sorted { pairs[$0.1]!.n != pairs[$1.1]!.n ? pairs[$0.1]!.n > pairs[$1.1]!.n : $0.0 < $1.0 }.map { ($0.1, pairs[$0.1]!) }
        let A = aOrder.enumerated().sorted { aps[$0.1]! != aps[$1.1]! ? aps[$0.1]! > aps[$1.1]! : $0.0 < $1.0 }.map { ($0.1, aps[$0.1]!) }
        let Ty = tOrder.enumerated().sorted { types[$0.1]! != types[$1.1]! ? types[$0.1]! > types[$1.1]! : $0.0 < $1.0 }.map { ($0.1, types[$0.1]!) }
        return (P, A, Ty)
    }
}

struct CurrencyBox: View {
    @EnvironmentObject var m: AppModel
    let all: [Entry]
    var body: some View {
        let c = currencyStatus(all)
        VStack(alignment: .leading, spacing: 10) {
            row("Day", "61.57(a)", c.day, "takeoffs", "landings")
            row("Night", "61.57(b)", c.night, "night takeoffs", "night full-stop landings")
            Small("Counts every logged takeoff and landing, including simulator sessions, in any aircraft. Your operator's rules (for example 14 CFR 121.439) and type requirements may differ, so treat this as a reminder, not a legal determination."
                  + (c.noTo ? " Some imported flights have no takeoff count, so one takeoff per landing is assumed for those." : ""))
        }
    }
    private func row(_ label: String, _ rule: String, _ s: CurrencyKind, _ toWord: String, _ ldgWord: String) -> some View {
        let soon = s.current && (s.until ?? "") <= addDays(todayIso(), 14)
        let need: (Recency) -> Int = { max(0, 3 - $0.in90) }
        let needs = [(need(s.to), toWord), (need(s.ldg), ldgWord)].filter { $0.0 > 0 }.map { "\($0.0) more \($0.1)" }.joined(separator: " and ")
        let text = s.current
            ? "Through \(fmtDate(s.until)). Last 90 days: \(s.to.in90) \(toWord), \(s.ldg.in90) \(ldgWord)."
            : "Last 90 days: \(s.to.in90) \(toWord), \(s.ldg.in90) \(ldgWord). Needs \(needs.isEmpty ? "3 within 90 days" : needs)."
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(label) · \(rule)").font(F.display(17, 600)).tracking(0.5).foregroundStyle(T.ink)
                Spacer()
                Chip(s.current ? (soon ? "⚠ Expires soon" : "✓ Current") : "✕ Not current", s.current ? (soon ? .pend : .ok) : .unsynced)
            }
            Small(text)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.line, lineWidth: 1))
    }
}

struct TopRow: Identifiable { let name: String; let n: Double; let sub: String; let note: String; let go: (() -> Void)?; var id: String { name } }

struct TopList: View {
    let rows: [TopRow]
    let empty: String
    var body: some View {
        if rows.isEmpty { Small(empty) } else {
            let max = rows[0].n
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { r in
                    Button { r.go?() } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Text(r.name).font(F.mono(14)).foregroundStyle(T.ink).lineLimit(1).truncationMode(.tail).frame(width: 105, alignment: .leading)
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4).fill(T.bg)
                                        UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 4, topTrailing: 4))
                                            .fill(T.bar).frame(width: g.size.width * Swift.max(0.04, r.n / Swift.max(max, 1e-9)))
                                    }.clipShape(RoundedRectangle(cornerRadius: 4))
                                }.frame(height: 8)
                                Text(r.sub).font(F.body(14)).foregroundStyle(T.muted).lineLimit(1).fixedSize()
                            }
                            if !r.note.isEmpty { Text(r.note).font(F.body(12)).foregroundStyle(T.muted).padding(.top, -4) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(r.go == nil)
                }
            }
        }
    }
}

struct Records: View {
    let es: [Entry]
    let fmt: String
    var body: some View {
        let flights = es.filter { !$0.sim && $0.t > 0 }
        var rows: [(String, String)] = []
        if let first = flights.first, let lastF = flights.last {
            let longest = flights.reduce(first) { $1.t > $0.t ? $1 : $0 }
            let far = flights.map { ($0, entryNm($0)) }.reduce((first, entryNm(first))) { $1.1 > $0.1 ? $1 : $0 }
            var months: [(String, Double)] = []
            for e in flights { let k = String(e.d.prefix(7)); if let i = months.firstIndex(where: { $0.0 == k }) { months[i].1 += e.t } else { months.append((k, e.t)) } }
            let best = months.reduce(months[0]) { $1.1 > $0.1 ? $1 : $0 }
            let rt: (Entry) -> String = { $0.r.joined(separator: "–") }
            rows.append(("Longest flight", "\(fmtHu(longest.t, fmt)) · \(rt(longest)) · \(fmtDate(longest.d))"))
            if far.1 > 0 { rows.append(("Farthest leg", "\(fmtNum(far.1)) nm · \(rt(far.0)) · \(fmtDate(far.0.d))")) }
            rows.append(("Busiest month", "\(fmtHu(best.1, fmt)) · \(fmtDate(best.0 + "-15", .monthYear))"))
            rows.append(("First flight", "\(fmtDate(first.d)) · \(rt(first).isEmpty ? "—" : rt(first))"))
            rows.append(("Most recent", "\(fmtDate(lastF.d)) · \(rt(lastF).isEmpty ? "—" : rt(lastF))"))
        }
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { k, v in
                GridRow {
                    Text(k).font(F.body(14)).foregroundStyle(T.muted).fixedSize()
                    Text(v).font(F.body(14)).monospacedDigit().foregroundStyle(T.ink).multilineTextAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

/// Hours by year/month (viewBox 520×200)
struct BarChart: View {
    let rows: [Bucket]
    let fmt: String
    let selected: String?
    var onTap: (Bucket) -> Void
    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in
                let W = 520.0, H = 200.0, padL = 34.0, padB = 22.0, padT = 16.0, padR = 6.0
                let s = size.width / W
                ctx.scaleBy(x: s, y: s)
                let mx = max(1, rows.map(\.t.total).max() ?? 0)
                let step: Double = mx > 600 ? 200 : mx > 300 ? 100 : mx > 120 ? 50 : mx > 40 ? 20 : mx > 16 ? 5 : 2
                let top = (mx / step).rounded(.up) * step
                let y: (Double) -> Double = { padT + (H - padT - padB) * (1 - $0 / top) }
                let slot = (W - padL - padR) / Double(max(1, rows.count)), bw = max(3, min(28, slot - 2))
                if let sel = selected, let i = rows.firstIndex(where: { $0.key == sel }) {
                    ctx.fill(Path(CGRect(x: padL + slot * Double(i), y: padT, width: slot, height: H - padT - padB)), with: .color(T.accentSoft))
                }
                var v = 0.0
                while v <= top {
                    var p = Path(); p.move(to: CGPoint(x: padL, y: y(v))); p.addLine(to: CGPoint(x: W - padR, y: y(v)))
                    ctx.stroke(p, with: .color(T.line), lineWidth: 1)
                    ctx.draw(Text(fmtNum(v)).font(F.mono(11)).foregroundStyle(T.muted), at: CGPoint(x: padL - 6, y: y(v)), anchor: .trailing)
                    v += step
                }
                let every = Int((Double(rows.count) / 12).rounded(.up))
                let best = rows.max { $0.t.total < $1.t.total }
                for (i, r) in rows.enumerated() {
                    let cx = padL + slot * Double(i) + slot / 2, x = cx - bw / 2, h = max(0, y(0) - y(r.t.total))
                    if h > 0 {
                        let rad = min(4, bw / 2, h)
                        let rect = CGRect(x: x, y: y(0) - h, width: bw, height: h)
                        ctx.fill(UnevenRoundedRectangle(cornerRadii: .init(topLeading: rad, bottomLeading: 0, bottomTrailing: 0, topTrailing: rad)).path(in: rect), with: .color(T.bar))
                    }
                    if every > 0 && i % every == 0 {
                        let lab = rows.count > 12 && !(r.label.count == 4 && Int(r.label) != nil) ? String(r.label.prefix(1)) : r.label
                        ctx.draw(Text(lab).font(F.display(11, 500)).foregroundStyle(T.muted), at: CGPoint(x: cx, y: H - 10), anchor: .center)
                    }
                    if let best, best.key == r.key, r.t.total > 0 {
                        ctx.draw(Text(fmtH(r.t.total, fmt)).font(F.mono(11, 600)).foregroundStyle(T.ink), at: CGPoint(x: cx, y: y(r.t.total) - 4), anchor: .bottom)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let W = 520.0, padL = 34.0, padR = 6.0
                let s = g.size.width / W
                let slot = (W - padL - padR) / Double(max(1, rows.count))
                let i = Int(((v.location.x / s) - padL) / slot)
                if i >= 0 && i < rows.count { onTap(rows[i]) }
            })
        }
    }
}

struct BarTable: View {
    let rows: [Bucket]
    let byYear: Bool
    let fmt: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .trailing, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array([byYear ? "Year" : "Month", "Flights", "Total", "PIC", "SIC", "Night", "Ldg"].enumerated()), id: \.offset) { i, h in
                        cell(Text(h).font(F.display(12, 600)).tracking(0.72).textCase(.uppercase).foregroundStyle(T.muted), first: i == 0)
                    }
                }
                ForEach(rows.reversed()) { r in
                    GridRow {
                        ForEach(Array([r.full, fmtNum(r.t.flights), fmtH(r.t.total, fmt), fmtH(r.t.pic, fmt), fmtH(r.t.sic, fmt), fmtH(r.t.night, fmt), fmtNum(r.t.l)].enumerated()), id: \.offset) { i, v in
                            cell(Text(v).font(F.body(13)).monospacedDigit().foregroundStyle(T.ink), first: i == 0)
                        }
                    }
                }
            }
        }
    }
    private func cell(_ t: some View, first: Bool) -> some View {
        t.lineLimit(1).fixedSize().padding(.vertical, 6).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: first ? .leading : .trailing)
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            .gridColumnAlignment(first ? .leading : .trailing)
    }
}

// MARK: - Search (same screen as Flight Tracker's History search)

struct SearchView: View {
    @EnvironmentObject var m: AppModel
    let all: [Entry]
    @State private var since = false

    var body: some View {
        let res = applyFind(all, m.find)
        let fmt = m.cfg.timeFmt
        VStack(alignment: .leading, spacing: 12) {
            TextField("", text: $m.find.q, prompt: prompt("Flight, airport, tail, type, month, night, >4…"))
                .textInputAutocapitalization(.characters).autocorrectionDisabled().submitLabel(.search)
                .inputChrome(size: 17, vpad: 12, hpad: 14, surface: true)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(FCHIPS, id: \.0) { k, l in
                    let on = m.find.st.contains(k)
                    Button { if on { m.find.st.remove(k) } else { m.find.st.insert(k) } } label: {
                        Text(l).font(F.display(14, 600)).tracking(0.56)
                            .foregroundStyle(on ? T.accentInk : T.muted)
                            .padding(.vertical, 7).padding(.horizontal, 12)
                            .background(Capsule().fill(on ? T.accent : T.surface))
                            .overlay(Capsule().stroke(on ? T.accent : T.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
            filters
            summary(res, fmt)
            results(res, fmt)
        }
        .sheet(isPresented: $since) {
            DateSheet(iso: Binding(get: { m.find.f["since"] ?? "" }, set: { m.find.f["since"] = $0 }), allowClear: true)
        }
    }

    private var filters: some View {
        let n = m.find.nFilters
        let uniq: ((Entry) -> String) -> [String] = { fn in Array(Set(all.map(fn).filter { !$0.isEmpty })).sorted() }
        return Disclosure(open: $m.findMoreOpen, arrow: "▾", summaryPadding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            Text("More filters" + (n > 0 ? " · \(n)" : "")).font(F.display(14, 600)).tracking(0.84).textCase(.uppercase).foregroundStyle(T.muted)
        } content: {
            LazyVGrid(columns: [GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top), GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top)], alignment: .leading, spacing: 10) {
                sel("year", "Year", uniq { String($0.d.prefix(4)) }.reversed().map { ($0, $0) })
                sel("mo", "Month", FMON.enumerated().map { (String($0.offset + 1), $0.element) })
                txt("dep", "From", "EWR")
                txt("arr", "To", "FLL")
                txt("ap", "Either airport", "MCO")
                txt("route", "Route", "EWR-FLL")
                sel("both", "Direction", [("1", "Both ways")], any: "As typed")
                sel("ac", "Aircraft type", uniq { $0.m }.map { ($0, $0) })
                txt("tail", "Registration", "N37560")
                sel("dow", "Day", FDOW.enumerated().map { (String($0.offset), $0.element) })
                txt("min", "At least", "3:00")
                txt("max", "At most", "1:30")
                ff("Since") {
                    Button { since = true } label: {
                        Text(m.find.f["since"].map { $0.isEmpty ? "Any" : fmtDate($0) } ?? "Any")
                            .foregroundStyle(m.find.f["since"]?.isEmpty == false ? T.ink : T.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).inputChrome(size: 15, vpad: 8, hpad: 9)
                    }.buttonStyle(.plain)
                }
                ff("Sort") { SelectBox(options: FSORT, value: m.find.sort, block: true) { m.find.sort = $0 } }
            }
            .padding(.horizontal, 16)
            Button("Clear all") { m.find = FindState() }.buttonStyle(BtnStyle()).padding(.horizontal, 16).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: T.r))
        .overlay(RoundedRectangle(cornerRadius: T.r).stroke(T.line, lineWidth: 1))
    }

    private func ff<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(F.display(12, 600)).tracking(0.96).textCase(.uppercase).foregroundStyle(T.muted)
            c()
        }
    }
    private func sel(_ k: String, _ label: String, _ opts: [(String, String)], any: String = "Any") -> some View {
        ff(label) { SelectBox(options: [("", any)] + opts, value: m.find.f[k] ?? "", block: true) { m.find.f[k] = $0 } }
    }
    private func txt(_ k: String, _ label: String, _ ph: String) -> some View {
        ff(label) {
            TextField("", text: Binding(get: { m.find.f[k] ?? "" }, set: { m.find.f[k] = $0.trimmingCharacters(in: .whitespaces) }), prompt: prompt(ph))
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .keyboardType(k == "min" || k == "max" ? .numbersAndPunctuation : .asciiCapable)
                .inputChrome(size: 15, vpad: 8, hpad: 9)
        }
    }

    private func summary(_ res: [Entry], _ fmt: String) -> some View {
        var t = 0.0, n = 0.0, l = 0, nm = 0.0
        for e in res { t += e.t; n += e.n; l += e.l; nm += entryNm(e) }
        return (Text(fmtNum(res.count)).font(F.mono(18, 600)).foregroundColor(T.ink)
                + Text(" flight\(res.count == 1 ? "" : "s") · \(fmtHu(t, fmt)) total · \(fmtH(n, fmt)) night · \(fmtNum(l)) ldg · \(fmtNum(nm)) nm").font(F.body(14)).foregroundColor(T.muted))
            .padding(.horizontal, 2)
    }

    @ViewBuilder private func results(_ res: [Entry], _ fmt: String) -> some View {
        if res.isEmpty {
            Card { Text("No flights match.").font(F.body(16)).foregroundStyle(T.muted).frame(maxWidth: .infinity).padding(.vertical, 28) }
        } else {
            let shown = Array(res.prefix(500))
            VStack(alignment: .leading, spacing: 12) {
                if m.find.sort == "new" || m.find.sort == "old" {
                    ForEach(Array(monthGroups(shown).enumerated()), id: \.offset) { _, g in
                        MonthHeader(text: g.0)
                        VStack(spacing: 8) { ForEach(g.1) { e in FindRow(e: e, fmt: fmt) } }
                    }
                } else {
                    VStack(spacing: 8) { ForEach(shown) { e in FindRow(e: e, fmt: fmt) } }
                }
                if res.count > shown.count { Small("Showing the first \(shown.count). Narrow the search to see the rest.") }
            }
        }
    }

    private func monthGroups(_ es: [Entry]) -> [(String, [Entry])] {
        var out: [(String, [Entry])] = []; var key = ""
        for e in es {
            let k = String(e.d.prefix(7))
            if k != key { key = k; out.append((fmtDate(k + "-15", .monthYear), [e])) } else { out[out.count - 1].1.append(e) }
        }
        return out
    }
}

struct FindRow: View {
    @EnvironmentObject var m: AppModel
    let e: Entry
    let fmt: String
    var body: some View {
        let meta = [fmtDate(e.d, .weekdayDay), e.fn.isEmpty ? "" : fltNo(e.fn), e.reg, e.m].filter { !$0.isEmpty }.joined(separator: " · ")
        let shell = RowShell(route: e.r.isEmpty ? "—" : e.r.joined(separator: "–"), meta: meta, time: fmtH(e.t, fmt)) {
            if e.sim { Chip("Sim") }
            else if let d = e.duty { Chip(d, d == "PF" ? .pf : .plain) }
            else if e.l > 0 { Chip("\(e.l) ldg") }
            if e.n > 0 { Chip("Night \(fmtH(e.n, fmt))", .night) }
            if e.ln > 0 { Chip("Night ldg", .night) }
            Chip(e.src == "app" ? "Logged here" : "MyFlightbook")
        }
        if e.src == "app", let id = e.flightID {
            Button { m.editFlight(id) } label: { shell }.buttonStyle(.plain)
        } else { shell }
    }
}
