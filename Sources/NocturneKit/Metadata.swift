// Nocturne: capture metadata read from EXIF (camera, lens, exposure, date).
import Foundation
import ImageIO

public struct PhotoMeta: Sendable, Hashable {
    public var width = 0
    public var height = 0
    public var camera: String?
    public var lens: String?
    public var iso: Int?
    public var shutter: Double?
    public var aperture: Double?
    public var focal: Double?
    public var date: Date?

    public init() {}

    public var shutterText: String? {
        guard let t = shutter, t > 0 else { return nil }
        if t >= 1 {
            return t == t.rounded() ? "\(Int(t)) s" : String(format: "%.1f s", t)
        }
        return "1/\(Int((1 / t).rounded())) s"
    }

    public var summary: String {
        var parts: [String] = []
        if let s = shutterText { parts.append(s) }
        if let a = aperture {
            parts.append(a == a.rounded() ? "f/\(Int(a))" : String(format: "f/%.1f", a))
        }
        if let iso { parts.append("ISO \(iso)") }
        if let f = focal { parts.append("\(Int(f.rounded())) mm") }
        return parts.joined(separator: " · ")
    }

    public static func read(_ url: URL) -> PhotoMeta {
        var m = PhotoMeta()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return m
        }
        m.width = (p[kCGImagePropertyPixelWidth] as? Int) ?? 0
        m.height = (p[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let exif = (p[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        let aux = (p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]) ?? [:]
        let tiff = (p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        m.camera = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        m.lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? (aux[kCGImagePropertyExifAuxLensModel] as? String)
        m.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        m.shutter = exif[kCGImagePropertyExifExposureTime] as? Double
        m.aperture = exif[kCGImagePropertyExifFNumber] as? Double
        m.focal = exif[kCGImagePropertyExifFocalLength] as? Double
        if let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            m.date = f.date(from: text)
        }
        return m
    }
}
