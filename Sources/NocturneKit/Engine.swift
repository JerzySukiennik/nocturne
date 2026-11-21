// Nocturne: image engine. Decodes RAW and regular photos into a linear working space and renders recipes on the GPU.
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

public enum EngineError: Error {
    case kernel(String)
    case unreadable(URL)
    case renderFailed
    case noDevice
}

public struct SourceImage: @unchecked Sendable {
    public let image: CIImage
    public let isRAW: Bool
    public let properties: [CFString: Any]
}

public final class Engine: @unchecked Sendable {
    public static let shared: Engine = {
        do {
            return try Engine()
        } catch {
            fatalError("Nocturne engine could not start: \(error)")
        }
    }()

    public let device: MTLDevice
    public let context: CIContext
    public let working: CGColorSpace
    public let output: CGColorSpace
    let kernels: Kernels

    public init() throws {
        let devices = MTLCopyAllDevices()
        guard let dev = devices.first(where: { $0.isLowPower }) ?? devices.first ?? MTLCreateSystemDefaultDevice() else {
            throw EngineError.noDevice
        }
        device = dev
        working = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        output = CGColorSpace(name: CGColorSpace.sRGB)!
        context = CIContext(mtlDevice: dev, options: [
            .workingFormat: CIFormat.RGBAh,
            .workingColorSpace: working,
            .cacheIntermediates: true
        ])
        kernels = try Kernels()
    }

    public static func isRAW(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .rawImage) ?? false
    }

    public func load(_ url: URL) throws -> SourceImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw EngineError.unreadable(url)
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        if Engine.isRAW(url), let raw = CIRAWFilter(imageURL: url), let out = raw.outputImage {
            guard let cg = context.createCGImage(out, from: out.extent, format: .RGBAh, colorSpace: working) else {
                throw EngineError.renderFailed
            }
            return SourceImage(image: CIImage(cgImage: cg), isRAW: true, properties: props)
        }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, options) else {
            throw EngineError.unreadable(url)
        }
        var img = CIImage(cgImage: cg)
        if let raw = props[kCGImagePropertyOrientation] as? UInt32, let orientation = CGImagePropertyOrientation(rawValue: raw) {
            img = img.oriented(orientation)
        }
        let e = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
        return SourceImage(image: img, isRAW: false, properties: props)
    }

    public func render(_ source: CIImage, recipe: Recipe, masks: MaskSet? = nil) -> CIImage {
        var img = source
        let extent = source.extent
        let long = max(extent.width, extent.height)
        for step in recipe.steps where step.on && !step.isNeutral {
            let next: CIImage?
            switch step.kind {
            case .light:
                let soft = softCopy(img, sigma: long * 0.02, down: 8)
                next = kernels.light.apply(extent: extent, arguments: [
                    img, soft,
                    step.value("exposure"),
                    step.value("contrast") / 100,
                    step.value("highlights") / 100,
                    step.value("shadows") / 100,
                    step.value("whites") / 100,
                    step.value("blacks") / 100
                ])
            case .color:
                next = kernels.color.apply(extent: extent, arguments: [
                    img,
                    step.value("temperature") / 100,
                    step.value("tint") / 100,
                    step.value("vibrance") / 100,
                    step.value("saturation") / 100
                ])
            case .grade:
                next = kernels.grade.apply(extent: extent, arguments: [
                    img,
                    step.value("shadowHue") / 360,
                    step.value("shadowAmount") / 100,
                    step.value("highlightHue") / 360,
                    step.value("highlightAmount") / 100,
                    step.value("balance") / 100
                ])
            case .splash:
                next = kernels.splash.apply(extent: extent, arguments: [
                    img,
                    step.value("hue") / 360,
                    step.value("range") / 360,
                    step.value("amount") / 100
                ])
            case .vignette:
                next = kernels.vignette.apply(extent: extent, arguments: [
                    img,
                    CIVector(x: extent.midX, y: extent.midY),
                    CIVector(x: extent.width / 2, y: extent.height / 2),
                    step.value("amount") / 100,
                    step.value("size") / 100
                ])
            case .mist:
                let spread = step.value("spread") / 100
                let soft = softCopy(img, sigma: long * (0.006 + 0.03 * spread), down: 4)
                next = kernels.mist.apply(extent: extent, arguments: [img, soft, step.value("amount") / 100])
            case .grain:
                let scale = (0.6 + 2.4 * step.value("size") / 100) * (long / 3872)
                let noise = CIFilter.randomGenerator().outputImage!
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .cropped(to: extent)
                next = kernels.grain.apply(extent: extent, arguments: [img, noise, step.value("amount") / 100])
            case .match:
                guard let d = step.data, d.count == Step.matchCount else { continue }
                func vec(_ i: Int) -> CIVector {
                    CIVector(x: d[i], y: d[i + 1], z: d[i + 2], w: d[i + 3])
                }
                next = kernels.match.apply(extent: extent, arguments: [
                    img, CIVector(x: d[0], y: d[1], z: d[14], w: d[15]),
                    vec(2), vec(16), vec(6), vec(20), vec(10), vec(24),
                    step.value("amount") / 100
                ])
            }
            guard let next else { continue }
            if let kind = step.mask {
                guard let mask = masks?.image(kind) else { continue }
                img = next.applyingFilter("CIBlendWithRedMask", parameters: [
                    kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask
                ])
            } else {
                img = next
            }
        }
        return img
    }

    func softCopy(_ img: CIImage, sigma: CGFloat, down: CGFloat) -> CIImage {
        let e = img.extent
        let small = img.transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
        let blurred = small.clampedToExtent()
            .applyingGaussianBlur(sigma: max(sigma / down, 0.5))
            .cropped(to: small.extent)
        return blurred.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: down, y: down))
            .cropped(to: e)
    }

    public func scaled(_ image: CIImage, maxEdge: CGFloat) -> CIImage {
        let e = image.extent
        let s = min(1, maxEdge / max(e.width, e.height))
        if s >= 1 { return image }
        let out = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let size = CGSize(width: floor(e.width * s), height: floor(e.height * s))
        return out.cropped(to: CGRect(origin: .zero, size: size))
    }

    public func cgImage(_ image: CIImage, maxEdge: CGFloat) -> CGImage? {
        let out = scaled(image, maxEdge: maxEdge)
        return context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: output)
    }

    public func jpegData(_ image: CIImage, maxEdge: CGFloat, quality: Double) -> Data? {
        let out = scaled(image, maxEdge: maxEdge)
        let key = kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption
        return context.jpegRepresentation(of: out, colorSpace: output, options: [key: quality])
    }

    public func export(_ image: CIImage, to url: URL, properties: [CFString: Any], quality: Double = 0.93) throws {
        var meta: [String: Any] = [:]
        let keep: [CFString] = [
            kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
            kCGImagePropertyExifAuxDictionary, kCGImagePropertyIPTCDictionary
        ]
        for key in keep {
            if let v = properties[key] { meta[key as String] = v }
        }
        var tiff = (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFSoftware] = "Nocturne"
        tiff[kCGImagePropertyTIFFOrientation] = 1
        meta[kCGImagePropertyTIFFDictionary as String] = tiff
        meta[kCGImagePropertyOrientation as String] = 1
        let key = kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption
        try context.writeJPEGRepresentation(of: image.settingProperties(meta), to: url, colorSpace: output, options: [key: quality])
    }
}
