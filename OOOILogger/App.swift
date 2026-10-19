import SwiftUI

@main
struct OOOILoggerApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task {
                    // Launch arguments used by the screenshot workflow (-openTab stats, -demoEdit 1, …)
                    let ud = UserDefaults.standard
                    if let t = ud.string(forKey: "openTab"), let tab = AppTab(rawValue: t) { model.show(tab) }
                    if ud.string(forKey: "openStats") == "search" { model.statsView = "search" }
                    await model.refresh()
                    if ud.bool(forKey: "demoEdit"), let f = model.flights.sorted(by: { $0.sortKey > $1.sortKey }).first { model.editFlight(f.id) }
                    if ud.string(forKey: "openTab") == "night" { model.openNight() }
                    if ud.bool(forKey: "scrollBottom") { try? await Task.sleep(nanoseconds: 1_000_000_000); model.scrollBottomToken += 1 }
                    // Refresh every minute while the app is open.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        if UIApplication.shared.applicationState == .active { await model.refresh() }
                    }
                }
                .onChange(of: phase) { _, p in if p == .active { Task { await model.refresh() } } }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HeaderView().id("top")
                        TabBarView()
                        content
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, m.tab == .log && !m.night ? 16 : 32)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: m.scrollToken) { _, _ in proxy.scrollTo("top", anchor: .top) }
                .onChange(of: m.scrollBottomToken) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .background(T.bg.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if m.tab == .log && !m.night { SaveBar() }
            }
            .overlay(alignment: .bottom) { ToastView() }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(T.accent)
        .sheet(item: $m.shareFile) { item in ShareSheet(items: [item.url]).ignoresSafeArea() }
    }

    @ViewBuilder var content: some View {
        if m.tab == .log && m.night { NightView() }
        else {
            switch m.tab {
            case .log: LogView()
            case .list: FlightsView()
            case .stats: StatsView()
            case .map: MapTabView()
            case .set: SettingsView()
            }
        }
    }
}

struct HeaderView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        let (kind, text) = m.statusLine
        let dot: Color = kind == .good ? T.good : kind == .warn ? T.warn : kind == .bad ? T.bad : T.muted
        let sync = HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(text).font(F.body(13, 500)).foregroundStyle(T.muted).lineLimit(2)
        }
        let title = HStack(alignment: .center, spacing: 10) {
            Text("OOOI Flight Logger").font(F.display(26, 700)).tracking(0.26).foregroundStyle(T.ink)
            Spacer(minLength: 0)
            HABadge()
        }
        VStack(alignment: .leading, spacing: 12) { title; sync }
    }
}

/// Green when the app is talking to the add-on on the Home Assistant box, gray when it isn't.
/// Tap it to check again (or to set it up).
struct HABadge: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        let on = m.conn == .ok
        Button {
            if m.conn == .notSetUp || m.conn == .needsLogin { m.show(.set) } else { Task { await m.refresh() } }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(on ? T.good : T.muted.opacity(0.7)).frame(width: 10, height: 10)
                Text("HA").font(F.display(13, 600)).tracking(0.78).foregroundStyle(on ? T.ink : T.muted)
            }
            .padding(.vertical, 5).padding(.horizontal, 10)
            .background(Capsule().fill(T.surface))
            .overlay(Capsule().stroke(T.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Connected to Home Assistant" : "Not connected to Home Assistant")
    }
}

struct TabBarView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        HStack(spacing: 3) {
            ForEach(AppTab.allCases, id: \.self) { t in
                let on = m.tab == t
                Button { m.show(t) } label: {
                    Text(t.title).font(F.display(14, 600)).tracking(0.28).textCase(.uppercase)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(on ? T.accentInk : T.muted)
                        .padding(.vertical, 9).padding(.horizontal, 2)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? T.accent : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: T.r))
        .overlay(RoundedRectangle(cornerRadius: T.r).stroke(T.line, lineWidth: 1))
    }
}

struct SaveBar: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        HStack(spacing: 10) {
            if m.editId != nil {
                Button("Delete") { m.showDelConfirm = true }.buttonStyle(BtnStyle(kind: .danger))
            }
            Button(m.editId != nil ? "Save changes" : "Save flight") { hideKeyboard(); m.saveFlight() }.buttonStyle(BtnStyle(kind: .primary))
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(T.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
    }
}

struct ToastView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        if let t = m.toastText {
            Text(t).font(F.body(14, 500)).foregroundStyle(T.bg)
                .padding(.vertical, 10).padding(.horizontal, 16)
                .background(Capsule().fill(T.ink))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.bottom, m.tab == .log && !m.night ? 84 : 24)
                .transition(.opacity)
                .onTapGesture { m.toastText = nil }
                .allowsHitTesting(true)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

func hideKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
