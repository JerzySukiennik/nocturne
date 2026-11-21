// Nocturne: Clean Up. Fills a painted region with plausible background using the LaMa model, locally on the CPU.
import CoreImage
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers

public final class Inpainter: @unchecked Sendable {
    public static let modelURL: URL = Masker.modelURL.deletingLastPathComponent().appendingPathComponent("LaMa.mlmodelc")

    private let engine: Engine
    private var model: MLModel?
    private var tried = false
    private var onGPU = true
    private let lock = NSLock()
    private let side = 800

    public init(engine: Engine) {
        self.engine = engine
    }

    public var available: Bool {
        FileManager.default.fileExists(atPath: Inpainter.modelURL.path)
    }

    private func load() -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        if tried { return model }
        tried = true
        let config = MLModelConfiguration()
        config.computeUnits = onGPU ? .cpuAndGPU : .cpuOnly
        model = try? MLModel(contentsOf: Inpainter.modelURL, configuration: config)
        return model
    }

    private func predict(_ image: CVPixelBuffer, _ mask: CVPixelBuffer) -> CVPixelBuffer? {
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: image),
            "mask": MLFeatureValue(pixelBuffer: mask)
        ]) else { return nil }
        if let model = load(), let out = try? model.prediction(from: input), let result = out.featureValue(for: "output")?.imageBufferValue {
            return result
        }
        guard onGPU else { return nil }
        lock.lock()
        onGPU = false
        tried = false
        model = nil
        lock.unlock()
        guard let model = load(), let out = try? model.prediction(from: input) else { return nil }
        return out.featureValue(for: "output")?.imageBufferValue
    }

    public func warmUp() {
        guard available, let image = buffer(kCVPixelFormatType_32BGRA), let mask = buffer(kCVPixelFormatType_OneComponent8) else { return }
        _ = predict(image, mask)
    }

    private func buffer(_ format: OSType) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, side, side, format, attrs, &out)
        return out
    }

    public func patch(base: CIImage, mask: CIImage, region: CGRect) -> CIImage? {
        guard available else { return nil }
        let extent = base.extent
        let limit = min(extent.width, extent.height)
        let size = min(max(max(region.width, region.height) * 2.4, 512), limit).rounded()
        var crop = CGRect(x: region.midX - size / 2, y: region.midY - size / 2, width: size, height: size)
        crop.origin.x = min(max(crop.origin.x, extent.minX), extent.maxX - size).rounded()
        crop.origin.y = min(max(crop.origin.y, extent.minY), extent.maxY - size).rounded()
        let k = CGFloat(side) / size
        let toModel = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            .concatenating(CGAffineTransform(scaleX: k, y: k))
        let frame = CGRect(x: 0, y: 0, width: side, height: side)
        let grow = max(4, size * 0.006)
        let hard = mask.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": grow]).cropped(to: extent)
        guard let imageBuffer = buffer(kCVPixelFormatType_32BGRA), let maskBuffer = buffer(kCVPixelFormatType_OneComponent8) else { return nil }
        engine.context.render(base.transformed(by: toModel).cropped(to: frame), to: imageBuffer, bounds: frame, colorSpace: engine.output)
        engine.context.render(hard.transformed(by: toModel).cropped(to: frame), to: maskBuffer, bounds: frame, colorSpace: nil)
        guard let result = predict(imageBuffer, maskBuffer) else { return nil }
        let filled = CIImage(cvPixelBuffer: result, options: [.colorSpace: engine.output])
        let back = filled.transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k)
            .concatenating(CGAffineTransform(translationX: crop.minX, y: crop.minY)))
        let feather = hard.clampedToExtent().applyingGaussianBlur(sigma: grow * 0.7).cropped(to: extent)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        return back.applyingFilter("CIBlendWithRedMask", parameters: [
            kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: feather
        ]).cropped(to: crop.intersection(extent))
    }
}

extension Engine {
    public func strokeMask(points: [CGPoint], radius: CGFloat, extent: CGRect) -> CIImage? {
        guard !points.isEmpty else { return nil }
        let s = min(1, 1536 / max(extent.width, extent.height))
        let w = Int(extent.width * s)
        let h = Int(extent.height * s)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(radius * 2 * s)
        let first = CGPoint(x: points[0].x * s, y: points[0].y * s)
        if points.count == 1 {
            ctx.fillEllipse(in: CGRect(x: first.x - radius * s, y: first.y - radius * s, width: radius * 2 * s, height: radius * 2 * s))
        } else {
            ctx.beginPath()
            ctx.move(to: first)
            for p in points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x * s, y: p.y * s)) }
            ctx.strokePath()
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(w), y: extent.height / CGFloat(h)))
            .cropped(to: extent)
    }

    public static func strokeRegion(points: [CGPoint], radius: CGFloat, extent: CGRect) -> CGRect {
        var box = CGRect.null
        for p in points {
            box = box.union(CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        }
        return box.intersection(extent)
    }

    public func cleaned(_ source: CIImage, recipe: Recipe, masks: MaskSet?) -> CIImage {
        var img = source
        for step in recipe.steps where step.kind == .cleanup && step.on {
            if let name = step.asset, let layer = masks?.layer(name) {
                img = layer.composited(over: img).cropped(to: source.extent)
            }
        }
        return img
    }

    public func flattenLayer(_ patch: CIImage, over old: CIImage?, extent: CGRect) -> CGImage? {
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        var layer = clear
        if let old { layer = old.composited(over: layer) }
        layer = patch.composited(over: layer)
        return context.createCGImage(layer, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
    }

    public func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
