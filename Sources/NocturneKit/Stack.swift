// Nocturne: series and stacks. Finds frames shot in a burst and merges them into one image: aligned average, lighten, or long exposure.
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public struct PhotoSeries: Identifiable, Sendable, Equatable {
    public let photos: [Photo]

    public var id: String { photos.first?.id ?? "" }
    public var count: Int { photos.count }
}

public enum StackMode: String, CaseIterable, Sendable {
    case average, lighten, longExposure

    public var title: String {
        switch self {
        case .average: return "Average"
        case .lighten: return "Lighten"
        case .longExposure: return "Long exposure"
        }
    }

    public var hint: String {
        switch self {
        case .average: return "Aligns the frames and averages them: the same picture with far less noise."
        case .lighten: return "Keeps the brightest value from every frame: star trails and light painting."
        case .longExposure: return "Averages without aligning: moving water and clouds turn silky."
        }
    }
}

extension Library {
    public static func findSeries(in photos: [Photo]) -> [PhotoSeries] {
        let dated = photos
            .filter { $0.meta.date != nil && !["tif", "tiff"].contains($0.url.pathExtension.lowercased()) }
            .sorted { ($0.meta.date ?? .distantPast, $0.name) < ($1.meta.date ?? .distantPast, $1.name) }
        var out: [PhotoSeries] = []
        var run: [Photo] = []
        func flush() {
            if run.count >= 3 { out.append(PhotoSeries(photos: run)) }
            run = []
        }
        for photo in dated {
            guard let last = run.last, let a = last.meta.date, let b = photo.meta.date else {
                flush()
                run = [photo]
                continue
            }
            let limit = max(6, (last.meta.shutter ?? 0) * 2.5 + 5)
            let same = photo.meta.camera == last.meta.camera && photo.meta.focal == last.meta.focal
                && photo.meta.width == last.meta.width && photo.meta.height == last.meta.height
            if same && b.timeIntervalSince(a) <= limit {
                run.append(photo)
            } else {
                flush()
                run = [photo]
            }
        }
        flush()
        return out.reversed()
    }

    public func stackURL(first: Photo, mode: StackMode, count: Int) -> URL {
        let base = first.url.deletingPathExtension().lastPathComponent
        return unique(folder(.toProcess).appendingPathComponent("\(base) \(mode.title) x\(count)").appendingPathExtension("tif"))
    }
}

extension Engine {
    public func stack(_ urls: [URL], mode: StackMode, progress: (Int) -> Void) throws -> (image: CGImage, properties: [CFString: Any], used: Int) {
        guard let firstURL = urls.first else { throw EngineError.renderFailed }
        let reference = try load(firstURL)
        let extent = reference.image.extent
        var acc = reference.image
        let alignEdge = max(extent.width, extent.height)
        let small = mode == .average ? cgImage(reference.image, maxEdge: alignEdge) : nil
        var inset: CGFloat = 0
        var used = 1
        progress(1)
        for (i, url) in urls.dropFirst().enumerated() {
            autoreleasepool {
                defer { progress(i + 2) }
                guard let frame = try? load(url), frame.image.extent.size == extent.size else { return }
                var img = frame.image
                if let small, let moving = cgImage(frame.image, maxEdge: alignEdge) {
                    let request = VNTranslationalImageRegistrationRequest(targetedCGImage: moving)
                    if (try? VNImageRequestHandler(cgImage: small).perform([request])) != nil,
                       let obs = request.results?.first as? VNImageTranslationAlignmentObservation {
                        let k = extent.width / CGFloat(small.width)
                        let dx = obs.alignmentTransform.tx * k
                        let dy = obs.alignmentTransform.ty * k
                        if abs(dx) < extent.width * 0.08, abs(dy) < extent.height * 0.08 {
                            img = img.clampedToExtent()
                                .transformed(by: CGAffineTransform(translationX: dx, y: dy))
                                .cropped(to: extent)
                            inset = max(inset, abs(dx), abs(dy))
                        }
                    }
                }
                let next: CIImage?
                if mode == .lighten {
                    next = img.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: acc])
                } else {
                    next = kernels.blend.apply(extent: extent, arguments: [acc, img, 1 / Double(used + 1)])
                }
                if let next, let cg = context.createCGImage(next, from: extent, format: .RGBAh, colorSpace: working) {
                    acc = CIImage(cgImage: cg)
                    used += 1
                }
            }
        }
        var out = acc
        if inset > 1 {
            let rect = extent.insetBy(dx: ceil(inset), dy: ceil(inset))
            out = acc.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let cg = context.createCGImage(out, from: out.extent, format: .RGBA16, colorSpace: space) else {
            throw EngineError.renderFailed
        }
        return (cg, reference.properties, used)
    }

    public func writeTIFF(_ image: CGImage, to url: URL, properties: [CFString: Any]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw EngineError.renderFailed
        }
        var meta: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary] {
            if let v = properties[key] { meta[key] = v }
        }
        var tiff = (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFSoftware] = "Nocturne"
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFCompression] = 5
        meta[kCGImagePropertyTIFFDictionary] = tiff
        CGImageDestinationAddImage(dest, image, meta as CFDictionary)
        if !CGImageDestinationFinalize(dest) { throw EngineError.renderFailed }
    }
}
