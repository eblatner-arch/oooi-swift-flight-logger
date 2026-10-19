import Foundation
import CoreGraphics

/// Coastline outlines from land.js (an SVG path in lon, −lat), parsed once in the background.
final class Land {
    static let shared = Land()
    private(set) var path: CGPath?
    private var started = false
    private var waiters: [() -> Void] = []

    func load(_ done: (() -> Void)? = nil) {
        if path != nil { done?(); return }
        if let done { waiters.append(done) }
        if started { return }
        started = true
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Land.parse()
            DispatchQueue.main.async {
                self.path = p
                let w = self.waiters; self.waiters = []
                w.forEach { $0() }
            }
        }
    }

    private static func parse() -> CGPath? {
        guard let url = Bundle.main.url(forResource: "land", withExtension: "js"),
              let data = try? Data(contentsOf: url) else { return nil }
        let p = CGMutablePath()
        var cmd: UInt8 = 0
        var nums: [Double] = []
        var i = data.startIndex
        // Skip to the opening quote of LAND_D="…"
        while i < data.endIndex && data[i] != UInt8(ascii: "\"") { i += 1 }
        i += 1
        var token = [UInt8]()
        func flushNumber() {
            if !token.isEmpty, let s = String(bytes: token, encoding: .ascii), let v = Double(s) { nums.append(v) }
            token.removeAll(keepingCapacity: true)
            if nums.count == 2 {
                let pt = CGPoint(x: nums[0], y: nums[1])
                if cmd == UInt8(ascii: "M") { p.move(to: pt); cmd = UInt8(ascii: "L") } else { p.addLine(to: pt) }
                nums.removeAll(keepingCapacity: true)
            }
        }
        while i < data.endIndex {
            let c = data[i]
            if c == UInt8(ascii: "\"") { break }
            switch c {
            case UInt8(ascii: "M"), UInt8(ascii: "L"):
                flushNumber(); cmd = c
            case UInt8(ascii: "Z"):
                flushNumber(); p.closeSubpath()
            case UInt8(ascii: " "), UInt8(ascii: ","):
                flushNumber()
            case UInt8(ascii: "-"):
                if !token.isEmpty { flushNumber() }
                token.append(c)
            default:
                token.append(c)
            }
            i += 1
        }
        flushNumber()
        return p
    }
}
