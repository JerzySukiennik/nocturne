// Nocturne: camera cards. Finds mounted cards with a DCIM folder, groups their photos by day and copies new ones into To Process.
import Foundation

public struct CardDay: Identifiable, Sendable, Equatable {
    public let day: Date
    public let files: [URL]
    public let fresh: Int

    public var id: Date { day }
}

public struct CameraCard: Identifiable, Sendable, Equatable {
    public let volume: URL
    public let name: String
    public let key: String
    public let total: Int
    public let newest: Date
    public let days: [CardDay]

    public var id: String { key }
}

extension Library {
    public func isImported(_ url: URL) -> Bool {
        let fm = FileManager.default
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let spots = [
            folder(.toProcess).appendingPathComponent(url.lastPathComponent),
            folder(.processed).appendingPathComponent("Originals").appendingPathComponent(url.lastPathComponent)
        ]
        for spot in spots where fm.fileExists(atPath: spot.path) {
            let other = (try? spot.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if other == size { return true }
        }
        return false
    }

    public func cards() -> [CameraCard] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsInternalKey]
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [CameraCard] = []
        let calendar = Calendar.current
        for volume in volumes {
            let dcim = volume.appendingPathComponent("DCIM")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dcim.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let values = try? volume.resourceValues(forKeys: Set(keys))
            if values?.volumeIsInternal == true { continue }
            var byDay: [Date: [(URL, Date)]] = [:]
            var newest = Date.distantPast
            var total = 0
            let walker = fm.enumerator(at: dcim, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])
            while let url = walker?.nextObject() as? URL {
                guard Library.isPhoto(url) else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                byDay[calendar.startOfDay(for: date), default: []].append((url, date))
                newest = max(newest, date)
                total += 1
            }
            guard total > 0 else { continue }
            let days = byDay.keys.sorted(by: >).map { day -> CardDay in
                let files = byDay[day]!.sorted { $0.1 < $1.1 }.map { $0.0 }
                return CardDay(day: day, files: files, fresh: files.filter { !isImported($0) }.count)
            }
            let name = values?.volumeName ?? volume.lastPathComponent
            out.append(CameraCard(volume: volume, name: name, key: values?.volumeUUIDString ?? name, total: total, newest: newest, days: days))
        }
        return out
    }

    public func importFromCard(_ files: [URL], progress: (Int) -> Void) -> Int {
        let fm = FileManager.default
        var count = 0
        for (i, url) in files.enumerated() {
            if !isImported(url) {
                let target = unique(folder(.toProcess).appendingPathComponent(url.lastPathComponent))
                if (try? fm.copyItem(at: url, to: target)) != nil { count += 1 }
            }
            progress(i + 1)
        }
        return count
    }
}
