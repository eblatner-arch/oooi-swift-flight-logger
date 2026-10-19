import SwiftUI

struct FlightsView: View {
    @EnvironmentObject var m: AppModel
    @State private var impConfirm = false

    var body: some View {
        let _ = m.apVersion
        let fl = m.flights.sorted { $0.sortKey > $1.sortKey }
        let pending = fl.filter { !$0.imported }
        let pendMin = pending.reduce(0) { s, x in let r = compute(x); return s + (r.ok ? r.totalMin : 0) }
        VStack(alignment: .leading, spacing: 12) {
            Card {
                ThreeCol {
                    StatTile(value: "\(pending.count)", label: "Pending import")
                    StatTile(value: fmtMin(pendMin, m.cfg.timeFmt), label: "Pending hours")
                    StatTile(value: "\(fl.count)", label: "Flights logged")
                }
                HStack(spacing: 10) {
                    Button("Sync to Drive") { Task { await m.syncDrive() } }.buttonStyle(BtnStyle(kind: .primary))
                    Button("Save CSV") { Task { await m.saveCsv() } }.buttonStyle(BtnStyle()).disabled(pending.isEmpty)
                }
                Button("Mark pending as imported") { impConfirm = true }.buttonStyle(BtnStyle()).disabled(pending.isEmpty)
                if impConfirm {
                    ConfirmBox(text: "Mark \(pending.count) pending flight\(pending.count == 1 ? "" : "s") as imported? Do this after MyFlightbook accepts the pending CSV.",
                               yes: "Mark imported", yesKind: .primary, no: "Cancel",
                               onYes: { impConfirm = false; m.markImported() }, onNo: { impConfirm = false })
                }
                Small(md: "Your Drive folder (and **/share/oooi_logger** on Home Assistant) keeps two files: **MyFlightbook Import – pending.csv** (only flights not yet imported) and **Flight Log – all flights.csv** (your full backup). Import the pending file, then mark those flights imported here.")
            }
            if fl.isEmpty {
                EmptyBlock(title: "No flights yet", text: "Scan an OOOI page on the Log tab. Saved flights show up here, in /share/oooi_logger, and in Drive.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(groups(fl).enumerated()), id: \.offset) { _, g in
                        MonthHeader(text: g.0)
                        ForEach(g.1) { f in FlightRow(f: f) }
                    }
                }
            }
        }
    }

    private func groups(_ fl: [Flight]) -> [(String, [Flight])] {
        var out: [(String, [Flight])] = []
        for f in fl {
            let mth = fmtDate(f.date, .monthYear)
            if out.last?.0 == mth { out[out.count - 1].1.append(f) } else { out.append((mth, [f])) }
        }
        return out
    }
}

struct MonthHeader: View {
    let text: String
    var body: some View {
        Text(text).font(F.display(15, 700)).tracking(1.2).textCase(.uppercase).foregroundStyle(T.muted)
            .padding(.top, 6).padding(.bottom, -6).padding(.horizontal, 2)
    }
}

struct FlightRow: View {
    @EnvironmentObject var m: AppModel
    let f: Flight
    var body: some View {
        let r = compute(f)
        Button { m.editFlight(f.id) } label: {
            RowShell(route: "\(f.from)–\(f.to)",
                     meta: "\(fmtDate(f.date, .weekdayDay)) · \(f.flightNumber.isEmpty ? "—" : fltNo(f.flightNumber)) · \(f.tail.isEmpty ? "no reg" : f.tail)",
                     time: r.ok ? fmtMin(r.totalMin, m.cfg.timeFmt) : "—") {
                Chip(f.duty.isEmpty ? "PF" : f.duty, f.duty == "PM" ? .plain : .pf)
                if r.ok && r.nightMin > 0 { Chip("Night \(fmtMin(r.nightMin, m.cfg.timeFmt))", .night) }
                if r.ok && f.duty == "PF" && r.nightLdg { Chip("Night ldg", .night) }
                Chip(f.imported ? "Imported" : "Pending", f.imported ? .ok : .pend)
            }
        }.buttonStyle(.plain)
    }
}

/// .flight: route and meta on the left, time on the right, chips underneath
struct RowShell<Chips: View>: View {
    let route: String
    let meta: String
    let time: String
    @ViewBuilder var chips: Chips
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(route).font(F.mono(18, 600)).tracking(0.36).foregroundStyle(T.ink)
                    Text(meta).font(F.body(13)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text(time).font(F.mono(18, 600)).foregroundStyle(T.ink)
            }
            FlowLayout { chips }
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: T.r))
        .overlay(RoundedRectangle(cornerRadius: T.r).stroke(T.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}
