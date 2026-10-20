import Foundation
import UIKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

/// How a photo of the ACARS-PREVIOUS OOOI page is read (Settings → Photo scanning → Scan method).
enum ScanMethod: String, CaseIterable, Identifiable {
    case geminiFull, geminiSmall, onDevice, appleAI
    var id: String { rawValue }
    var title: String {
        switch self {
        case .geminiFull: return "Gemini · full photo"
        case .geminiSmall: return "Gemini · small photo"
        case .onDevice: return "On iPhone · text recognition"
        case .appleAI: return "On iPhone · Apple Intelligence"
        }
    }
    var detail: String {
        switch self {
        case .geminiFull: return "1600 px color photo to Home Assistant, then Gemini. Most accurate; slow on weak signal."
        case .geminiSmall: return "1024 px grayscale photo (about a sixth of the size) to Home Assistant, then Gemini."
        case .onDevice: return "Apple's text recognition reads the page on the iPhone and the app picks the values by their labels. Nothing is uploaded; works with no signal."
        case .appleAI: return "Text recognition on the iPhone, then Apple's on-device model fills in the fields. Nothing is uploaded. Needs iOS 26 and Apple Intelligence."
        }
    }
    static var current: ScanMethod {
        get { ScanMethod(rawValue: UserDefaults.standard.string(forKey: "scanMethod") ?? "") ?? .geminiFull }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "scanMethod") }
    }
}

/// Grayscale, smaller JPEG for the "small photo" method.
func smallGrayJPEG(_ img: UIImage) -> Data? {
    let small = downscale(img, 1024)
    guard let cg = small.cgImage else { return small.jpegData(compressionQuality: 0.6) }
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return small.jpegData(compressionQuality: 0.6) }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let g = ctx.makeImage() else { return small.jpegData(compressionQuality: 0.6) }
    return UIImage(cgImage: g).jpegData(compressionQuality: 0.6)
}

// MARK: - On-device text recognition (Vision)

/// One recognized word with its box (Vision's normalized coordinates, origin bottom-left).
struct OCRWord { var s: String; var r: CGRect }

struct OCRResult {
    var words: [OCRWord]
    var lines: [String]      // reading order, for the Apple Intelligence prompt and the debug view
}

func recognizeText(_ img: UIImage) async throws -> OCRResult {
    let src = downscale(img, 2400)
    guard let cg = src.cgImage else { return OCRResult(words: [], lines: []) }
    let orientation = CGImagePropertyOrientation(src.imageOrientation)
    final class Once { var done = false; let lock = NSLock()
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true } }
    let once = Once()
    return try await withCheckedThrowingContinuation { cont in
        let req = VNRecognizeTextRequest { req, err in
            guard once.claim() else { return }
            if let err { cont.resume(throwing: err); return }
            let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
            var words: [OCRWord] = []
            var lineItems: [(CGRect, String)] = []
            for o in obs {
                guard let c = o.topCandidates(1).first else { continue }
                lineItems.append((o.boundingBox, c.string))
                // split into words with their own boxes
                var idx = c.string.startIndex
                for part in c.string.split(separator: " ", omittingEmptySubsequences: true) {
                    guard let range = c.string.range(of: part, range: idx..<c.string.endIndex) else { continue }
                    idx = range.upperBound
                    let box = (try? c.boundingBox(for: range))?.boundingBox ?? o.boundingBox
                    words.append(OCRWord(s: String(part), r: box))
                }
            }
            // reading order: top to bottom (Vision y grows upward), then left to right
            lineItems.sort { abs($0.0.midY - $1.0.midY) > 0.012 ? $0.0.midY > $1.0.midY : $0.0.minX < $1.0.minX }
            cont.resume(returning: OCRResult(words: words, lines: lineItems.map(\.1)))
        }
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.customWords = ["ACARS", "OOOI", "CREW", "OUT", "OFF", "ON", "IN", "TRIP", "FLT", "NBR", "DEP", "DES"]
        let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation)
        DispatchQueue.global(qos: .userInitiated).async {
            do { try handler.perform([req]) } catch { if once.claim() { cont.resume(throwing: error) } }
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// The CDU shows zeros with a slash; text recognition reads them as Ø, O, D or Q.
private func digitsFix(_ s: String) -> String {
    let map: [Character: Character] = ["Ø": "0", "ø": "0", "O": "0", "o": "0", "D": "0", "Q": "0", "I": "1", "l": "1", "|": "1", "S": "5", "B": "8", "Z": "2"]
    return String(s.map { map[$0] ?? $0 })
}
private func clean(_ s: String) -> String { s.uppercased().replacingOccurrences(of: "Ø", with: "0").trimmingCharacters(in: .punctuationCharacters) }

/// Picks the OOOI values out of the recognized words by their labels. On the CDU each value sits
/// under its label (or right after it on the same line).
func parseOOOI(_ ocr: OCRResult) -> JSON {
    let words = ocr.words.map { OCRWord(s: clean($0.s), r: $0.r) }.filter { !$0.s.isEmpty }
    let labels = ["CREW", "OUT", "OFF", "ON", "IN"]
    var used = Set<Int>()
    var out: JSON = [:]

    func isTime(_ s: String) -> String? {
        let d = digitsFix(s).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: ".", with: "")
        guard d.count == 4, d.allSatisfy(\.isNumber), let h = Int(d.prefix(2)), let mi = Int(d.suffix(2)), h < 24, mi < 60 else { return nil }
        return d
    }
    func isTrip(_ s: String) -> String? {
        let d = digitsFix(s)
        guard d.range(of: #"^\d{1,2}:?\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let digits = d.filter(\.isNumber)
        return "\(digits.dropLast(2)):\(digits.suffix(2))"
    }
    /// The value for a label: below it (next CDU line, left edges close) or to its right on the same line.
    func valueFor(_ li: Int, _ test: (String) -> String?) -> String? {
        let L = words[li].r
        var best: (Int, Double, String)?
        for (i, w) in words.enumerated() where i != li && !used.contains(i) {
            guard let v = test(w.s) else { continue }
            let dy = L.midY - w.r.midY            // > 0 means the word is lower on the page
            let dx = w.r.minX - L.minX
            var score: Double
            if abs(dy) < L.height * 0.6 && w.r.minX >= L.maxX - 0.005 {
                score = Double(w.r.minX - L.maxX) * 2 + 0.02          // same line, to the right
            } else if dy > 0 && dy < L.height * 4 && abs(dx) < max(L.width, w.r.width) * 1.2 {
                score = Double(dy) + Double(abs(dx)) * 0.5           // below, roughly aligned
            } else { continue }
            if best == nil || score < best!.1 { best = (i, score, v) }
        }
        if let b = best { used.insert(b.0); return b.2 }
        return nil
    }

    for lab in labels {
        if let li = words.firstIndex(where: { $0.s == lab }), let v = valueFor(li, isTime) { out[lab == "IN" ? "in" : lab.lowercased()] = v }
        else if let w = words.first(where: { $0.s.hasPrefix(lab) && isTime(String($0.s.dropFirst(lab.count))) != nil }) {
            out[lab == "IN" ? "in" : lab.lowercased()] = isTime(String(w.s.dropFirst(lab.count)))
        }
    }
    if let li = words.firstIndex(where: { $0.s == "TRIP" }), let v = valueFor(li, isTrip) { out["trip"] = v }

    // DEP/DES: "KORD/KDEN", or two airport codes in reading order
    var codes: [String] = []
    for w in words {
        for part in w.s.split(whereSeparator: { $0 == "/" || $0 == "-" }) {
            let p = String(part).replacingOccurrences(of: "0", with: "O")
            if p.count == 4, p.allSatisfy({ $0.isLetter }), AP[p] != nil, !["CREW", "TRIP", "ACARS", "OOOI"].contains(p), !codes.contains(p) { codes.append(p) }
        }
    }
    if codes.count >= 1 { out["from"] = codes[0] }
    if codes.count >= 2 { out["to"] = codes[1] }

    // FLT NBR: the number under/after "FLT" or "NBR"
    if let li = words.firstIndex(where: { $0.s == "NBR" || $0.s == "FLT" || $0.s == "FLTNBR" }) {
        let fn = valueFor(li) { s in
            let d = digitsFix(s.replacingOccurrences(of: "UA", with: "").replacingOccurrences(of: "UAL", with: ""))
            return (1...4).contains(d.count) && d.allSatisfy(\.isNumber) ? String(Int(d) ?? 0) : nil
        }
        if let fn { out["flightNumber"] = fn }
    }
    let n = ["crew", "out", "off", "on", "in"].filter { out[$0] != nil }.count
    out["confidence"] = n == 5 && out["from"] != nil && out["to"] != nil ? "medium" : "low"
    out["notes"] = ""
    return out
}

// MARK: - Apple Intelligence (Foundation Models, iOS 26)

enum AppleAI {
    /// Why Apple Intelligence can't be used here, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let r):
                switch r {
                case .deviceNotEligible: return "This iPhone doesn't support Apple Intelligence."
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in iPhone Settings."
                case .modelNotReady: return "Apple Intelligence is still downloading its model. Try again later."
                @unknown default: return "Apple Intelligence isn't available right now."
                }
            }
        }
        return "Needs iOS 26."
        #else
        return "This build was made without the iOS 26 SDK."
        #endif
    }

    static func read(_ ocr: OCRResult) async throws -> JSON {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: """
                You read text recognized from a photo of a Boeing FMC/CDU screen showing the airline ACARS page titled "ACARS-PREVIOUS OOOI". \
                The labels are FLT NBR (flight number, digits only), DEP/DES (departure and destination ICAO codes written like KORD/KDEN), \
                CREW, OUT, OFF, ON, IN (four-digit UTC times HHMM) and TRIP (total time HH:MM). Each value is on the line under its label. \
                The screen shows zeros with a slash, which text recognition may read as Ø, O or D: treat those as 0 in numbers. \
                Use an empty string for any value you cannot find.
                """)
            let r = try await session.respond(to: "Recognized text, one screen line per line:\n" + ocr.lines.joined(separator: "\n"),
                                              generating: OOOIFields.self)
            let c = r.content
            return ["flightNumber": c.flightNumber, "from": c.departure, "to": c.destination, "crew": c.crew, "out": c.out,
                    "off": c.off, "on": c.on, "in": c.inTime, "trip": c.trip, "confidence": "medium", "notes": ""]
        }
        #endif
        throw APIError(message: unavailableReason ?? "Apple Intelligence isn't available.", status: 400)
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct OOOIFields {
    @Guide(description: "FLT NBR, digits only") var flightNumber: String
    @Guide(description: "DEP, 4-letter ICAO code") var departure: String
    @Guide(description: "DES, 4-letter ICAO code") var destination: String
    @Guide(description: "CREW time, HHMM") var crew: String
    @Guide(description: "OUT time, HHMM") var out: String
    @Guide(description: "OFF time, HHMM") var off: String
    @Guide(description: "ON time, HHMM") var on: String
    @Guide(description: "IN time, HHMM") var inTime: String
    @Guide(description: "TRIP time, HH:MM") var trip: String
}
#endif
