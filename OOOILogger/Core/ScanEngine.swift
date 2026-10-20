import Foundation
import UIKit

/// How the photo of the ACARS-PREVIOUS OOOI page is sent for reading (Settings → Photo scanning → Photo size).
enum ScanMethod: String, CaseIterable, Identifiable {
    case geminiTiny, geminiSmall, geminiFull
    var id: String { rawValue }
    var title: String {
        switch self {
        case .geminiTiny: return "Tiny photo"
        case .geminiSmall: return "Small photo"
        case .geminiFull: return "Full photo"
        }
    }
    var detail: String {
        switch self {
        case .geminiTiny: return "800 px grayscale, lower quality (about half the small photo) to Home Assistant, then to the AI. Fastest on a very weak signal; small digits are more likely to be misread."
        case .geminiSmall: return "1024 px grayscale photo (about a sixth of the full photo) to Home Assistant, then to the AI. Best on weak signal."
        case .geminiFull: return "1600 px color photo to Home Assistant, then to the AI. Slower to upload on weak signal."
        }
    }
    var maxSide: CGFloat { self == .geminiTiny ? 800 : self == .geminiSmall ? 1024 : 1600 }
    static var current: ScanMethod {
        get { ScanMethod(rawValue: UserDefaults.standard.string(forKey: "scanMethod") ?? "") ?? .geminiSmall }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "scanMethod") }
    }
    /// The JPEG sent for this method.
    func jpeg(_ img: UIImage) -> Data? {
        switch self {
        case .geminiTiny: return grayJPEG(img, 800, 0.45)
        case .geminiSmall: return grayJPEG(img, 1024, 0.6)
        case .geminiFull: return downscale(img, 1600).jpegData(compressionQuality: 0.88)
        }
    }
}

/// Grayscale, smaller JPEG.
func grayJPEG(_ img: UIImage, _ maxSide: CGFloat, _ quality: CGFloat) -> Data? {
    let small = downscale(img, maxSide)
    guard let cg = small.cgImage else { return small.jpegData(compressionQuality: quality) }
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return small.jpegData(compressionQuality: quality) }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let g = ctx.makeImage() else { return small.jpegData(compressionQuality: quality) }
    return UIImage(cgImage: g).jpegData(compressionQuality: quality)
}
