// Nocturne: tethering. Talks to a camera over USB in PTP mode: fires the shutter, pulls new frames into To Process, imports older ones by day.
import Foundation
import ImageCaptureCore

public struct TetherDay: Identifiable, Sendable, Equatable {
    public let day: Date
    public let count: Int
    public let fresh: Int

    public var id: Date { day }
}

public final class CameraLink: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate, @unchecked Sendable {
    public var onChange: (() -> Void)?
    public var onFrame: ((URL) -> Void)?
    public private(set) var name: String?
    public private(set) var ready = false
    public private(set) var days: [TetherDay] = []
    public private(set) var total = 0

    private let library: Library
    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var known = Set<String>()
    private var expecting = 0
    private var importLeft = 0
    private var importAdded = 0
    private var importDone: ((Int) -> Void)?
    private var transaction: UInt32 = 1

    public init(library: Library) {
        self.library = library
    }

    public func start() {
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        browser.start()
    }

    public func stop() {
        camera?.requestCloseSession()
        browser.stop()
    }

    public static func message(for code: UInt16) -> String? {
        switch code {
        case 0x2001: return nil
        case 0x2013: return "The camera cannot reach its memory card. Turn the camera off and on, then try again."
        case 0x2019: return "The camera is busy. Try again in a moment."
        case 0x200C: return "The memory card is full."
        case 0xA002: return "The camera could not focus. Switch to manual focus or aim at something with contrast."
        default: return String(format: "The camera refused the shot (code 0x%04X).", code)
        }
    }

    public func capture(_ completion: @escaping (String?) -> Void) {
        guard let camera, ready else {
            completion("No camera is ready.")
            return
        }
        var bytes = [UInt8]()
        func put32(_ v: UInt32) {
            for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) }
        }
        func put16(_ v: UInt16) {
            bytes.append(UInt8(v & 0xff))
            bytes.append(UInt8(v >> 8))
        }
        transaction += 1
        put32(20)
        put16(1)
        put16(0x100E)
        put32(transaction)
        put32(0)
        put32(0)
        camera.requestSendPTPCommand(Data(bytes), outData: nil) { [weak self] _, response, error in
            DispatchQueue.main.async {
                let r = [UInt8](response)
                if let error {
                    completion(error.localizedDescription)
                    return
                }
                let code = r.count >= 8 ? UInt16(r[6]) | (UInt16(r[7]) << 8) : 0
                let message = CameraLink.message(for: code)
                if message == nil { self?.expecting += 1 }
                completion(message)
            }
        }
    }

    public func importDay(_ day: Date, completion: @escaping (Int) -> Void) {
        guard let camera, importDone == nil else {
            completion(0)
            return
        }
        let calendar = Calendar.current
        let files = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.filter { file in
            guard let name = file.name, let date = file.creationDate, calendar.startOfDay(for: date) == day else { return false }
            return !library.isImported(name: name, size: Int(file.fileSize))
        }
        guard !files.isEmpty else {
            completion(0)
            return
        }
        importLeft = files.count
        importAdded = 0
        importDone = completion
        for file in files { download(file) }
    }

    private func download(_ file: ICCameraFile) {
        camera?.requestDownloadFile(file, options: [.downloadsDirectoryURL: library.folder(.toProcess)], downloadDelegate: self,
                                    didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)), contextInfo: nil)
    }

    @objc public func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String: Any] = [:], contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [self] in
            let saved = options[ICDownloadOption.savedFilename.rawValue] as? String ?? file.name ?? ""
            let url = library.folder(.toProcess).appendingPathComponent(saved)
            if importDone != nil {
                if error == nil { importAdded += 1 }
                importLeft -= 1
                if importLeft <= 0 {
                    let done = importDone
                    importDone = nil
                    rebuildDays()
                    done?(importAdded)
                }
            } else if error == nil {
                onFrame?(url)
            }
        }
    }

    private func rebuildDays() {
        let calendar = Calendar.current
        var byDay: [Date: (Int, Int)] = [:]
        var count = 0
        for case let file as ICCameraFile in camera?.mediaFiles ?? [] {
            guard let name = file.name, Library.isPhoto(URL(fileURLWithPath: name)) else { continue }
            let day = calendar.startOfDay(for: file.creationDate ?? .distantPast)
            var entry = byDay[day] ?? (0, 0)
            entry.0 += 1
            if !library.isImported(name: name, size: Int(file.fileSize)) { entry.1 += 1 }
            byDay[day] = entry
            count += 1
        }
        total = count
        days = byDay.keys.sorted(by: >).map { TetherDay(day: $0, count: byDay[$0]!.0, fresh: byDay[$0]!.1) }
        onChange?()
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard camera == nil, let cam = device as? ICCameraDevice, device.transportType == ICDeviceTransport.transportTypeUSB.rawValue else { return }
        camera = cam
        name = cam.name
        ready = false
        cam.delegate = self
        cam.requestOpenSession()
        onChange?()
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard device === camera else { return }
        camera = nil
        name = nil
        ready = false
        days = []
        total = 0
        known = []
        expecting = 0
        onChange?()
    }

    public func didRemove(_ device: ICDevice) {}
    public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        known = Set((device.mediaFiles ?? []).compactMap { $0.name })
        ready = true
        rebuildDays()
    }

    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        guard ready else { return }
        for case let file as ICCameraFile in items {
            guard let name = file.name, !known.contains(name) else { continue }
            known.insert(name)
            if expecting > 0 {
                expecting -= 1
                download(file)
            }
        }
        rebuildDays()
    }

    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
