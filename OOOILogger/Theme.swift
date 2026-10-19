import SwiftUI
import UIKit

// Colors and type copied from the add-on's app.css (light and dark tokens).

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

enum T {
    static let bg = Color.dyn(0xedf0f3, 0x0e1318)
    static let surface = Color.dyn(0xffffff, 0x161d25)
    static let ink = Color.dyn(0x16202b, 0xe5eaef)
    static let muted = Color.dyn(0x5a6878, 0x93a1b0)
    static let line = Color.dyn(0xd2d9e1, 0x29333e)
    static let accent = Color.dyn(0x0e7c88, 0x4cc7d3)
    static let accentInk = Color.dyn(0xffffff, 0x062126)
    static let accentSoft = Color.dyn(0xdcf0f2, 0x143238)
    static let cdu = Color.dyn(0x10161d, 0x07090c)
    static let cduInk = Color(hex: 0xf2f5f7)
    static let cduLabel = Color(hex: 0x57d0dc)
    static let cduLine = Color.dyn(0x2a3542, 0x26303b)
    static let cduFoot = Color(hex: 0x9aa8b5)
    static let cduPlaceholder = Color(hex: 0x4b5866)
    static let cduOk = Color(hex: 0x7fe0a6)
    static let cduNo = Color(hex: 0xffb38a)
    static let good = Color.dyn(0x1d7f48, 0x59c487)
    static let goodSoft = Color.dyn(0xe0f2e8, 0x15301f)
    static let warn = Color.dyn(0x9a6512, 0xe2ad55)
    static let warnSoft = Color.dyn(0xf8edd9, 0x33260f)
    static let bad = Color.dyn(0xb3362a, 0xf08273)
    static let badSoft = Color.dyn(0xf8e1de, 0x3a1a16)
    static let water = Color.dyn(0xdce6ee, 0x0b1824)
    static let land = Color.dyn(0xf7f9fb, 0x1d2732)
    static let coast = Color.dyn(0xb9c6d2, 0x34414f)
    static let day = Color.dyn(0xb5700f, 0xe8a948)
    static let daySoft = Color.dyn(0xf8ecd6, 0x33260f)
    static let twi = Color.dyn(0x7a52c7, 0xb393f2)
    static let twiSoft = Color.dyn(0xece5f8, 0x2a2140)
    static let night = Color.dyn(0x135f9e, 0x6cb4f0)
    static let nightSoft = Color.dyn(0xdde9f5, 0x14273a)
    static let bar = Color.dyn(0x008a9c, 0x2aa6b6)
    static let r: CGFloat = 10
}

enum F {
    /// Barlow Semi Condensed (500, 600, 700)
    static func display(_ size: CGFloat, _ w: Int = 600) -> Font {
        .custom(w >= 700 ? "BarlowSemiCondensed-Bold" : w >= 600 ? "BarlowSemiCondensed-SemiBold" : "BarlowSemiCondensed-Medium", fixedSize: size)
    }
    /// Barlow (400, 500, 600)
    static func body(_ size: CGFloat, _ w: Int = 400) -> Font {
        .custom(w >= 600 ? "Barlow-SemiBold" : w >= 500 ? "Barlow-Medium" : "Barlow-Regular", fixedSize: size)
    }
    /// IBM Plex Mono (500, 600)
    static func mono(_ size: CGFloat, _ w: Int = 500) -> Font {
        .custom(w >= 600 ? "IBMPlexMono-SemiBold" : "IBMPlexMono-Medium", fixedSize: size).monospacedDigit()
    }
    static func uiMono(_ size: CGFloat, _ w: Int = 500) -> UIFont {
        UIFont(name: w >= 600 ? "IBMPlexMono-SemiBold" : "IBMPlexMono-Medium", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .medium)
    }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    var spacing: CGFloat = 14
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.surface)
            .clipShape(RoundedRectangle(cornerRadius: T.r))
            .overlay(RoundedRectangle(cornerRadius: T.r).stroke(T.line, lineWidth: 1))
    }
}

/// .label: 600 12px display, uppercase, .08em, muted
struct LabelText: View {
    let text: String
    var color: Color = T.muted
    init(_ text: String, color: Color = T.muted) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(F.display(12, 600)).tracking(0.96).textCase(.uppercase).foregroundStyle(color)
    }
}

struct Small: View {
    let text: Text
    var color: Color = T.muted
    init(_ s: String, color: Color = T.muted) { text = Text(s); self.color = color }
    init(md: String, color: Color = T.muted) { text = Text(LocalizedStringKey(md)); self.color = color }
    init(text: Text, color: Color = T.muted) { self.text = text; self.color = color }
    var body: some View {
        text.font(F.body(13)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).tint(T.accent)
    }
}

enum BtnKind { case normal, primary, danger }

struct BtnStyle: ButtonStyle {
    var kind: BtnKind = .normal
    var size: CGFloat = 16
    var vpad: CGFloat = 12
    var hpad: CGFloat = 14
    var block = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(F.display(size, 600)).tracking(size * 0.04).textCase(.uppercase)
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(kind == .primary ? T.accentInk : kind == .danger ? T.bad : T.ink)
            .padding(.vertical, vpad).padding(.horizontal, hpad)
            .frame(maxWidth: block ? .infinity : nil)
            .background(kind == .primary ? T.accent : T.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(kind == .primary ? T.accent : T.line, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
            .contentShape(Rectangle())
    }
}

struct LinkBtn: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) { Text(title).font(F.body(14, 600)).foregroundStyle(T.accent).padding(.vertical, 2) }
            .buttonStyle(.plain)
    }
}

struct SegOption: Identifiable { let v: String; let title: String; var small: String? = nil; var id: String { v } }

/// .seg: two equal buttons, accent when pressed
struct Seg: View {
    let options: [SegOption]
    let value: String
    var onPick: (String) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.1.id) { i, o in
                if i > 0 { Rectangle().fill(T.line).frame(width: 1) }
                Button { onPick(o.v) } label: {
                    VStack(spacing: 2) {
                        Text(o.title).font(F.display(18, 700)).tracking(0.9)
                        if let s = o.small { Text(s).font(F.body(12, 500)) }
                    }
                    .foregroundStyle(o.v == value ? T.accentInk : T.muted)
                    .padding(.vertical, 12).padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .background(o.v == value ? T.accent : T.bg)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.line, lineWidth: 1))
    }
}

enum ChipKind { case plain, night, day, pf, ok, pend, unsynced, keyDay, keyTwi, keyNight }

struct Chip: View {
    let text: String
    var kind: ChipKind = .plain
    init(_ text: String, _ kind: ChipKind = .plain) { self.text = text; self.kind = kind }
    var colors: (Color, Color, Color) {
        switch kind {
        case .plain: return (T.bg, T.muted, T.line)
        case .night: return (T.cdu, T.cduLabel, T.cdu)
        case .day: return (T.warnSoft, T.warn, .clear)
        case .pf: return (T.accentSoft, T.accent, .clear)
        case .ok: return (T.goodSoft, T.good, .clear)
        case .pend: return (T.warnSoft, T.warn, .clear)
        case .unsynced: return (T.badSoft, T.bad, .clear)
        case .keyDay: return (T.daySoft, T.day, .clear)
        case .keyTwi: return (T.twiSoft, T.twi, .clear)
        case .keyNight: return (T.nightSoft, T.night, .clear)
        }
    }
    var body: some View {
        let c = colors
        Text(text).font(F.display(12, 600)).tracking(0.72).textCase(.uppercase)
            .foregroundStyle(c.1).padding(.vertical, 4).padding(.horizontal, 8)
            .background(Capsule().fill(c.0)).overlay(Capsule().stroke(c.2, lineWidth: 1))
            .lineLimit(1)
    }
}

/// .stat: big mono value over a small muted label
struct StatTile: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(F.mono(22, 600)).foregroundStyle(T.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(F.body(12)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// .calc / .summary: three equal columns
struct ThreeCol<Content: View>: View {
    var hspacing: CGFloat = 10
    var vspacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: hspacing, alignment: .topLeading), count: 3),
                  alignment: .leading, spacing: vspacing) { content }
    }
}

enum MsgKind { case plain, good, warn, bad }
struct MsgBox: View {
    let kind: MsgKind
    let text: String
    var body: some View {
        let (bg, fg): (Color, Color) = {
            switch kind { case .plain: return (T.bg, T.ink); case .good: return (T.goodSoft, T.good)
            case .warn: return (T.warnSoft, T.warn); case .bad: return (T.badSoft, T.bad) }
        }()
        Text(text).font(F.body(14)).foregroundStyle(fg).padding(.vertical, 9).padding(.horizontal, 11)
            .frame(maxWidth: .infinity, alignment: .leading).background(bg).clipShape(RoundedRectangle(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// .confirm: red-bordered box with a question and two buttons
struct ConfirmBox: View {
    let text: String
    let yes: String
    var yesKind: BtnKind = .danger
    let no: String
    var onYes: () -> Void
    var onNo: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(F.body(16)).foregroundStyle(T.ink).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(yes, action: onYes).buttonStyle(BtnStyle(kind: yesKind))
                Button(no, action: onNo).buttonStyle(BtnStyle())
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(T.badSoft).clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.bad, lineWidth: 1))
    }
}

/// input, select, textarea: 500 17px, bg, 1px line, radius 8, padding 10 11
struct InputChrome: ViewModifier {
    var mono = false
    var size: CGFloat = 17
    var vpad: CGFloat = 10
    var hpad: CGFloat = 11
    var highlight = false
    var surface = false
    func body(content: Content) -> some View {
        content
            .font(mono ? F.mono(size, 500) : F.body(size, 500))
            .foregroundStyle(T.ink).tint(T.accent)
            .padding(.vertical, vpad).padding(.horizontal, hpad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface ? T.surface : T.bg)
            .clipShape(RoundedRectangle(cornerRadius: surface ? 10 : 8))
            .overlay(RoundedRectangle(cornerRadius: surface ? 10 : 8).stroke(highlight ? T.accent : T.line, lineWidth: 1))
    }
}
extension View {
    func inputChrome(mono: Bool = false, size: CGFloat = 17, vpad: CGFloat = 10, hpad: CGFloat = 11, highlight: Bool = false, surface: Bool = false) -> some View {
        modifier(InputChrome(mono: mono, size: size, vpad: vpad, hpad: hpad, highlight: highlight, surface: surface))
    }
}

func prompt(_ s: String, _ color: Color = T.muted.opacity(0.5)) -> Text { Text(s).foregroundStyle(color) }

/// A select-style box that opens a menu
struct SelectBox: View {
    let options: [(String, String)]
    let value: String
    var size: CGFloat = 15
    var block = false
    var onPick: (String) -> Void
    var body: some View {
        Menu {
            ForEach(options, id: \.0) { o in
                Button { onPick(o.0) } label: { if o.0 == value { Label(o.1, systemImage: "checkmark") } else { Text(o.1) } }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first(where: { $0.0 == value })?.1 ?? options.first?.1 ?? "").lineLimit(1)
                if block { Spacer(minLength: 0) }
                Image(systemName: "chevron.down").font(.system(size: size * 0.7, weight: .semibold)).foregroundStyle(T.muted)
            }
            .font(F.body(size, 500)).foregroundStyle(T.ink)
            .padding(.vertical, 8).padding(.horizontal, 10)
            .frame(maxWidth: block ? .infinity : nil, alignment: .leading)
            .background(T.bg).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line, lineWidth: 1))
        }
    }
}

struct CheckBox: View {
    let on: Bool
    var enabled = true
    var size: CGFloat = 22
    var toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(on ? T.accent : T.bg)
                RoundedRectangle(cornerRadius: 5).stroke(on ? T.accent : T.muted.opacity(0.6), lineWidth: 1.2)
                if on { Image(systemName: "checkmark").font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(T.accentInk) }
            }.frame(width: size, height: size)
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }
}

/// details.card: a card with a tappable summary that opens and closes
struct Disclosure<Label: View, Content: View>: View {
    @Binding var open: Bool
    var arrow = "▸"           // ▸ rotates 90°; ▾ rotates 180°
    var summaryPadding: EdgeInsets = EdgeInsets()
    @ViewBuilder var label: Label
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: open ? 14 : 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack {
                    label
                    Spacer()
                    Text(arrow).font(.system(size: 14)).foregroundStyle(T.muted)
                        .rotationEffect(.degrees(open ? (arrow == "▸" ? 90 : 180) : 0))
                }.padding(summaryPadding).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open { content }
        }
    }
}

/// Wrapping row of views (flex-wrap)
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, w: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += sz.width + spacing; lineH = max(lineH, sz.height); w = max(w, x - spacing)
        }
        return CGSize(width: proposal.width ?? w, height: y + lineH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; lineH = max(lineH, sz.height)
        }
    }
}

struct EmptyBlock: View {
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(F.display(18, 600)).foregroundStyle(T.ink)
            Text(text).font(F.body(16)).foregroundStyle(T.muted).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 28).padding(.horizontal, 12).frame(maxWidth: .infinity)
    }
}

/// Narrow screens (≤ 400 pt) get the 3-column CDU grid, like the web app's media query.
var isNarrow: Bool { UIScreen.main.bounds.width <= 400 }
