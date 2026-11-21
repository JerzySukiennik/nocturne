// Nocturne: semantic masks and the depth map. Subject, person and background from Vision; sky, near, far and depth from a local depth model.
import Accelerate
import CoreImage
import CoreML
import Foundation
import Vision

public final class MaskSet: @unchecked Sendable {
    private var images: [MaskKind: CIImage] = [:]
    private var layers: [String: CIImage] = [:]
    private var depthImage: CIImage?
    private var depthValues: [Float] = []
    private var depthWidth = 0
    private var depthHeight = 0
    private let lock = NSLock()

    public init() {}

    public func image(_ kind: MaskKind) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[kind]
    }

    public func set(_ image: CIImage, for kind: MaskKind) {
        lock.lock()
        images[kind] = image
        lock.unlock()
    }

    public var ready: Set<MaskKind> {
        lock.lock()
        defer { lock.unlock() }
        return Set(images.keys)
    }

    public func layer(_ name: String) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return layers[name]
    }

    public func setLayer(_ image: CIImage, name: String) {
        lock.lock()
        layers[name] = image
        lock.unlock()
    }

    public func keepingLayers() -> MaskSet {
        let next = MaskSet()
        lock.lock()
        next.layers = layers
        lock.unlock()
        return next
    }

    public var depth: CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return depthImage
    }

    func setDepth(_ image: CIImage, values: [Float], width: Int, height: Int) {
        lock.lock()
        depthImage = image
        depthValues = values
        depthWidth = width
        depthHeight = height
        lock.unlock()
    }

    public func depthValue(x: Double, yFromTop: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard depthWidth > 0, depthHeight > 0 else { return nil }
        let px = min(max(Int(x * Double(depthWidth)), 0), depthWidth - 1)
        let py = min(max(Int(yFromTop * Double(depthHeight)), 0), depthHeight - 1)
        return Double(depthValues[py * depthWidth + px])
    }
}

public final class Masker: @unchecked Sendable {
    public static let modelURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Nocturne/Models/DepthAnythingV2SmallF16.mlmodelc")

    private let engine: Engine
    private var model: VNCoreMLModel?
    private var triedModel = false
    private let lock = NSLock()

    public init(engine: Engine) {
        self.engine = engine
    }

    public var depthAvailable: Bool {
        FileManager.default.fileExists(atPath: Masker.modelURL.path)
    }

    private func depthModel() -> VNCoreMLModel? {
        lock.lock()
        defer { lock.unlock() }
        if triedModel { return model }
        triedModel = true
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        if let ml = try? MLModel(contentsOf: Masker.modelURL, configuration: config) {
            model = try? VNCoreMLModel(for: ml)
        }
        return model
    }

    public func prepare(_ recipe: Recipe, source: CIImage, into set: MaskSet) {
        compute(recipe.maskKinds, depth: recipe.needsDepth, source: engine.cleaned(source, recipe: recipe, masks: set), into: set)
    }

    public func compute(_ kinds: Set<MaskKind>, depth wantDepth: Bool = false, source: CIImage, into set: MaskSet) {
        let missing = kinds.subtracting(set.ready)
        let depthMissing = wantDepth && set.depth == nil
        guard !missing.isEmpty || depthMissing, let cg = engine.cgImage(source, maxEdge: 1536) else { return }
        let extent = source.extent
        let frame = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let raw: [CIImageOption: Any] = [.colorSpace: NSNull()]
        let empty = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)

        if missing.contains(.subject) || missing.contains(.background) {
            var mask: CIImage?
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cg)
            if (try? handler.perform([request])) != nil, let obs = request.results?.first, !obs.allInstances.isEmpty,
               let buffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
                mask = CIImage(cvPixelBuffer: buffer, options: raw)
            }
            if let mask {
                let fitted = fit(mask, to: frame)
                set.set(finish(fitted, frame: frame, extent: extent) ?? empty, for: .subject)
                set.set(finish(fitted.applyingFilter("CIColorInvert"), frame: frame, extent: extent) ?? empty, for: .background)
            } else {
                set.set(empty, for: .subject)
                set.set(CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent), for: .background)
            }
        }

        if missing.contains(.person) {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            var mask: CIImage?
            if (try? VNImageRequestHandler(cgImage: cg).perform([request])) != nil, let obs = request.results?.first {
                mask = CIImage(cvPixelBuffer: obs.pixelBuffer, options: raw)
            }
            set.set(mask.flatMap { finish(fit($0, to: frame), frame: frame, extent: extent) } ?? empty, for: .person)
        }

        let depthKinds = missing.filter { $0.needsDepth }
        guard !depthKinds.isEmpty || depthMissing, let model = depthModel() else { return }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        guard (try? VNImageRequestHandler(cgImage: cg).perform([request])) != nil,
              let obs = request.results?.first as? VNPixelBufferObservation,
              let floats = floatValues(obs.pixelBuffer) else { return }
        let data = floats.values.withUnsafeBufferPointer { Data(buffer: $0) }
        let small = CIImage(bitmapData: data, bytesPerRow: floats.width * 4,
                            size: CGSize(width: floats.width, height: floats.height), format: .Rf, colorSpace: nil)
        let depth = fit(small, to: frame)
        let guide = CIImage(cgImage: cg)
        if set.depth == nil {
            let refined = depth.applyingFilter("CIGuidedFilter", parameters: [
                "inputGuideImage": guide, "inputRadius": 6.0, "inputEpsilon": 0.0006
            ]).cropped(to: frame)
            if let out = engine.context.createCGImage(refined, from: frame, format: .RGBAh, colorSpace: engine.working) {
                set.setDepth(CIImage(cgImage: out, options: raw), values: floats.values, width: floats.width, height: floats.height)
            }
        }
        for kind in depthKinds {
            let args: [Any]
            switch kind {
            case .sky: args = [depth, 0.002, 0.008, 1.0]
            case .far: args = [depth, 0.10, 0.35, 1.0]
            default: args = [depth, 0.40, 0.70, 0.0]
            }
            guard var mask = engine.kernels.step.apply(extent: frame, arguments: args) else { continue }
            mask = mask.applyingFilter("CIGuidedFilter", parameters: [
                "inputGuideImage": guide, "inputRadius": 8.0, "inputEpsilon": 0.0008
            ]).cropped(to: frame)
            if kind == .sky {
                mask = mask.clampedToExtent().applyingGaussianBlur(sigma: frame.width * 0.004).cropped(to: frame)
            }
            set.set(finish(mask, frame: frame, extent: extent) ?? empty, for: kind)
        }
    }

    private func floatValues(_ buffer: CVPixelBuffer) -> (values: [Float], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), w > 0, h > 0 else { return nil }
        var values = [Float](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half:
            var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
            values.withUnsafeMutableBytes { raw in
                var dst = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
            }
        case kCVPixelFormatType_OneComponent32Float:
            values.withUnsafeMutableBytes { raw in
                for y in 0..<h {
                    memcpy(raw.baseAddress!.advanced(by: y * w * 4), base.advanced(by: y * rowBytes), w * 4)
                }
            }
        default:
            return nil
        }
        return (values, w, h)
    }

    private func fit(_ image: CIImage, to frame: CGRect) -> CIImage {
        let e = image.extent
        let t = CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: frame.width / e.width, y: frame.height / e.height))
        return image.clampedToExtent().transformed(by: t).cropped(to: frame)
    }

    private func finish(_ mask: CIImage, frame: CGRect, extent: CGRect) -> CIImage? {
        guard let cg = engine.context.createCGImage(mask, from: frame, format: .RGBA8, colorSpace: engine.working) else { return nil }
        let image = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        let t = CGAffineTransform(scaleX: extent.width / frame.width, y: extent.height / frame.height)
        return image.clampedToExtent().transformed(by: t).cropped(to: extent)
    }
}
