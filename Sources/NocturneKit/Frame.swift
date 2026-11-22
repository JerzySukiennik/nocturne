// Nocturne: framed exports. A white or black border with a "Shot on" caption, an optional note, and a before / after layout.
import AppKit
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FrameStyle: String, CaseIterable, Sendable {
    case plain, frame, compare

    public var title: String {
        switch self {
        case .plain: return "Plain"
        case .frame: return "Frame"
        case .compare: return "Before / After"
        }
    }
}

public struct FrameOptions: Sendable, Equatable {
    public var style: FrameStyle
    public var dark: Bool
    public var device: String
    public var settings: String
    public var note: String

    public init(style: FrameStyle = .plain, dark: Bool = false, device: String = "", settings: String = "", note: String = "") {
        self.style = style
        self.dark = dark
        self.device = device
        self.settings = settings
        self.note = note
    }
}

extension PhotoMeta {
    public var deviceName: String {
        guard let camera, !camera.isEmpty else { return "" }
        var words = camera.split(separator: " ").map(String.init)
        if let first = words.first, first.count > 3, first == first.uppercased(), first.rangeOfCharacter(from: .decimalDigits) == nil {
            words[0] = first.capitalized
        }
        return words.joined(separator: " ")
    }

    public var settingsLine: String {
        if (camera ?? "").localizedCaseInsensitiveContains("iPhone") { return "" }
        var parts: [String] = []
        if let f = focal { parts.append("\(Int(f.rounded())) mm") }
        if let a = aperture { parts.append(a == a.rounded() ? "f/\(Int(a))" : String(format: "f/%.1f", a)) }
        if let s = shutterText { parts.append(s) }
        if let iso { parts.append("ISO \(iso)") }
        return parts.joined(separator: "  ·  ")
    }
}

extension Engine {
    public func framed(after: CIImage, before: CIImage?, options: FrameOptions, maxEdge: CGFloat? = nil) -> CGImage? {
        var photos: [CIImage] = [after]
        if options.style == .compare, let before { photos = [before, after] }
        let e = after.extent
        let long = max(e.width, e.height)
        let margin = long * 0.045
        let band = long * 0.135
        let gap = long * 0.06
        let n = CGFloat(photos.count)
        let fullW = e.width + margin * 2
        let fullH = margin + n * e.height + (n - 1) * gap + band
        var s: CGFloat = 1
        if let maxEdge { s = min(1, maxEdge / max(fullW, fullH)) }
        let w = Int((fullW * s).rounded())
        let h = Int((fullH * s).rounded())
        let pw = (e.width * s).rounded()
        let ph = (e.height * s).rounded()
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: output, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let background = options.dark ? CGColor(red: 0.035, green: 0.035, blue: 0.04, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let primary = options.dark ? CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1) : CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        let secondary = options.dark ? CGColor(red: 0.62, green: 0.62, blue: 0.65, alpha: 1) : CGColor(red: 0.45, green: 0.45, blue: 0.48, alpha: 1)
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high

        let x0 = (margin * s).rounded()
        var top = CGFloat(h) - (margin * s).rounded()
        var bottoms: [CGFloat] = []
        for photo in photos {
            let fitted = photo.transformed(by: CGAffineTransform(scaleX: pw / photo.extent.width, y: ph / photo.extent.height))
            let rect = CGRect(x: 0, y: 0, width: pw, height: ph)
            guard let cg = context.createCGImage(fitted, from: rect, format: .RGBA8, colorSpace: output) else { return nil }
            ctx.draw(cg, in: CGRect(x: x0, y: top - ph, width: pw, height: ph))
            bottoms.append(top - ph)
            top -= ph + (gap * s).rounded()
        }

        func line(_ parts: [(String, NSFont, CGColor)], kern: CGFloat = 0) -> CTLine {
            let text = NSMutableAttributedString()
            for part in parts {
                text.append(NSAttributedString(string: part.0, attributes: [
                    .font: part.1,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): part.2,
                    .kern: kern
                ]))
            }
            return CTLineCreateWithAttributedString(text)
        }
        func width(_ l: CTLine) -> CGFloat {
            CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
        }
        func draw(_ l: CTLine, x: CGFloat, y: CGFloat) {
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(l, ctx)
        }

        let big = long * 0.0215 * s
        let small = long * 0.0145 * s
        let tiny = long * 0.0105 * s
        let right = x0 + pw
        let bandMid = (band * s) * 0.5
        let device = options.device.trimmingCharacters(in: .whitespaces)
        let settings = options.settings.trimmingCharacters(in: .whitespaces)
        let note = options.note.trimmingCharacters(in: .whitespaces)

        if !device.isEmpty {
            let title = line([
                ("Shot on ", NSFont.systemFont(ofSize: big, weight: .regular), secondary),
                (device, NSFont.systemFont(ofSize: big, weight: .semibold), primary)
            ])
            if settings.isEmpty {
                draw(title, x: right - width(title), y: bandMid - big * 0.35)
            } else {
                let detail = line([(settings, NSFont.systemFont(ofSize: small, weight: .regular), secondary)])
                draw(title, x: right - width(title), y: bandMid + small * 0.25)
                draw(detail, x: right - width(detail), y: bandMid - small * 1.25)
            }
        }
        if !note.isEmpty {
            let text = line([(note, NSFont.systemFont(ofSize: big, weight: .regular), primary)])
            draw(text, x: x0, y: bandMid - big * 0.35)
        }
        if photos.count == 2 {
            let labels = ["BEFORE", "AFTER"]
            for (i, bottom) in bottoms.enumerated() {
                let label = line([(labels[i], NSFont.systemFont(ofSize: tiny, weight: .semibold), secondary)], kern: tiny * 0.14)
                draw(label, x: x0, y: bottom - tiny * 2.1)
            }
        }
        return ctx.makeImage()
    }

    public func writeJPEG(_ image: CGImage, to url: URL, properties: [CFString: Any], quality: Double = 0.93) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw EngineError.renderFailed
        }
        var meta: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality, kCGImagePropertyOrientation: 1]
        let keep: [CFString] = [
            kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
            kCGImagePropertyExifAuxDictionary, kCGImagePropertyIPTCDictionary
        ]
        for key in keep {
            if let v = properties[key] { meta[key] = v }
        }
        var tiff = (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFSoftware] = "Nocturne"
        tiff[kCGImagePropertyTIFFOrientation] = 1
        meta[kCGImagePropertyTIFFDictionary] = tiff
        CGImageDestinationAddImage(dest, image, meta as CFDictionary)
        if !CGImageDestinationFinalize(dest) { throw EngineError.renderFailed }
    }
}
