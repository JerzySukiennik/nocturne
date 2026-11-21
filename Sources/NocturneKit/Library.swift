// Nocturne: photo library on two plain folders (To Process, Processed), recipes saved beside the photos, thumbnails.
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Shelf: String, CaseIterable, Sendable {
    case toProcess = "To Process"
    case processed = "Processed"
}

public struct Photo: Identifiable, Hashable, Sendable {
    public let url: URL
    public let shelf: Shelf
    public let meta: PhotoMeta
    public let modified: Date
    public let edited: Bool

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public var sortDate: Date { meta.date ?? modified }
}

struct Project: Codable {
    var original: String
    var recipe: Recipe
}

public final class Library: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    public init(root: URL? = nil) {
        self.root = root ?? fm.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Nocturne")
    }

    public func folder(_ shelf: Shelf) -> URL {
        root.appendingPathComponent(shelf.rawValue)
    }

    func hidden(_ shelf: Shelf) -> URL {
        folder(shelf).appendingPathComponent(".nocturne")
    }

    var originals: URL {
        folder(.processed).appendingPathComponent("Originals")
    }

    public func prepare() throws {
        for shelf in Shelf.allCases {
            try fm.createDirectory(at: hidden(shelf), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
    }

    public static func isPhoto(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .pdf) && type != .svg
    }

    public func scan(_ shelf: Shelf) -> [Photo] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let items = (try? fm.contentsOfDirectory(at: folder(shelf), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var out: [Photo] = []
        for url in items where Library.isPhoto(url) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let draft = Photo(url: url, shelf: shelf, meta: PhotoMeta.read(url), modified: values?.contentModificationDate ?? .distantPast, edited: false)
            let edited = shelf == .processed ? true : loadRecipe(for: draft).hasEffect
            out.append(Photo(url: url, shelf: shelf, meta: draft.meta, modified: draft.modified, edited: edited))
        }
        return out.sorted { $0.sortDate > $1.sortDate }
    }

    public func count(_ shelf: Shelf) -> Int {
        let items = (try? fm.contentsOfDirectory(at: folder(shelf), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { Library.isPhoto($0) }.count
    }

    public func recipeURL(for photo: Photo) -> URL {
        hidden(photo.shelf).appendingPathComponent(photo.name + ".json")
    }

    func project(for photo: Photo) -> Project? {
        guard photo.shelf == .processed, let data = try? Data(contentsOf: recipeURL(for: photo)) else { return nil }
        return try? JSONDecoder().decode(Project.self, from: data)
    }

    func originalURL(_ project: Project) -> URL? {
        let url = folder(.processed).appendingPathComponent(project.original)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    public func sourceURL(for photo: Photo) -> URL {
        if let p = project(for: photo), let original = originalURL(p) { return original }
        return photo.url
    }

    public func loadRecipe(for photo: Photo) -> Recipe {
        if photo.shelf == .processed {
            guard let p = project(for: photo), originalURL(p) != nil else { return Recipe() }
            return p.recipe
        }
        guard let data = try? Data(contentsOf: recipeURL(for: photo)),
              let recipe = try? JSONDecoder().decode(Recipe.self, from: data) else {
            return Recipe()
        }
        return recipe
    }

    public func saveRecipe(_ recipe: Recipe, for photo: Photo) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = recipeURL(for: photo)
        if photo.shelf == .processed {
            guard var p = project(for: photo), originalURL(p) != nil else { return }
            p.recipe = recipe
            if let data = try? encoder.encode(p) { try? data.write(to: url, options: .atomic) }
            return
        }
        if recipe.steps.isEmpty {
            try? fm.removeItem(at: url)
        } else if let data = try? encoder.encode(recipe) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func recipeStamp(for photo: Photo) -> Date? {
        (try? recipeURL(for: photo).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func unique(_ url: URL) -> URL {
        if !fm.fileExists(atPath: url.path) { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    public static func cleanName(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>.").union(.newlines).union(.controlCharacters)
        let parts = text.components(separatedBy: banned).joined(separator: " ")
        let squeezed = parts.split(separator: " ").joined(separator: " ")
        return String(squeezed.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    public func importFiles(_ urls: [URL]) -> Int {
        var count = 0
        for url in urls where Library.isPhoto(url) {
            let target = unique(folder(.toProcess).appendingPathComponent(url.lastPathComponent))
            if (try? fm.copyItem(at: url, to: target)) != nil { count += 1 }
        }
        return count
    }

    public func export(photo: Photo, recipe: Recipe, name: String, image: CIImage, properties: [CFString: Any], engine: Engine) throws -> URL {
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if photo.shelf == .processed {
            try engine.export(image, to: photo.url, properties: properties)
            saveRecipe(recipe, for: photo)
            return photo.url
        }
        let clean = Library.cleanName(name)
        let base = clean.isEmpty ? photo.url.deletingPathExtension().lastPathComponent : clean
        let target = unique(folder(.processed).appendingPathComponent(base).appendingPathExtension("jpg"))
        try engine.export(image, to: target, properties: properties)
        let kept = unique(originals.appendingPathComponent(photo.name))
        try fm.moveItem(at: photo.url, to: kept)
        let project = Project(original: "Originals/" + kept.lastPathComponent, recipe: recipe)
        let projectURL = hidden(.processed).appendingPathComponent(target.lastPathComponent + ".json")
        try encoder.encode(project).write(to: projectURL, options: .atomic)
        try? fm.removeItem(at: recipeURL(for: photo))
        return target
    }

    public func trash(_ photo: Photo) throws {
        try fm.trashItem(at: photo.url, resultingItemURL: nil)
        try? fm.removeItem(at: recipeURL(for: photo))
    }

    public func watch(_ onChange: @escaping @Sendable () -> Void) {
        for shelf in Shelf.allCases {
            let fd = open(folder(shelf).path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                self?.pending?.cancel()
                let work = DispatchWorkItem { onChange() }
                self?.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }
}

public final class ThumbnailStore: @unchecked Sendable {
    public static let edge: CGFloat = 640
    private let engine: Engine
    private let library: Library
    private let cache = NSCache<NSString, CGImage>()
    private let dir: URL
    private let queue: OperationQueue

    public init(engine: Engine, library: Library) {
        self.engine = engine
        self.library = library
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("fun.gzowo.nocturne/thumbs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        cache.countLimit = 600
    }

    public func key(for photo: Photo) -> String {
        let stamp = library.recipeStamp(for: photo)?.timeIntervalSince1970 ?? 0
        let text = "\(photo.url.path)|\(photo.modified.timeIntervalSince1970)|\(stamp)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func cached(_ photo: Photo) -> CGImage? {
        cache.object(forKey: key(for: photo) as NSString)
    }

    public func store(_ image: CGImage, for photo: Photo) {
        let k = key(for: photo)
        cache.setObject(image, forKey: k as NSString)
        write(image, to: dir.appendingPathComponent(k + ".jpg"))
    }

    public func image(for photo: Photo) async -> CGImage? {
        let k = key(for: photo)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        return await withCheckedContinuation { continuation in
            queue.addOperation { [self] in
                let file = dir.appendingPathComponent(k + ".jpg")
                var result = read(file)
                if result == nil {
                    result = make(photo)
                    if let result { write(result, to: file) }
                }
                if let result { cache.setObject(result, forKey: k as NSString) }
                continuation.resume(returning: result)
            }
        }
    }

    private func make(_ photo: Photo) -> CGImage? {
        let recipe = photo.shelf == .toProcess ? library.loadRecipe(for: photo) : Recipe()
        if recipe.hasEffect, let source = try? engine.load(photo.url) {
            return engine.cgImage(engine.render(source.image, recipe: recipe), maxEdge: ThumbnailStore.edge)
        }
        guard let src = CGImageSourceCreateWithURL(photo.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: ThumbnailStore.edge,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    private func read(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
