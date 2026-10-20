import Foundation
import UIKit

/// How the photo of the ACARS-PREVIOUS OOOI page is sent to Gemini (Settings → Photo scanning → Scan method).
enum ScanMethod: String, CaseIterable, Identifiable {
    case geminiSmall, geminiFull
    var id: String { rawValue }
    var title: String {
        switch self {
        case .geminiSmall: return "Gemini · small photo"
        case .geminiFull: return "Gemini · full photo"
        }
    }
    var detail: String {
        switch self {
        case .geminiSmall: return "1024 px grayscale photo (about a sixth of the size) to Home Assistant, then Gemini. Best on weak signal."
        case .geminiFull: return "1600 px color photo to Home Assistant, then Gemini. Slower to upload on weak signal."
        }
    }
    static var current: ScanMethod {
        get { ScanMethod(rawValue: UserDefaults.standard.string(forKey: "scanMethod") ?? "") ?? .geminiSmall }
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
