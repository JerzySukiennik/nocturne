// Nocturne: camera probe. Lists cameras seen over USB, their abilities and files; with "shoot" it fires the shutter and downloads the new frame. Usage: camera-probe [shoot] [outdir]
import Foundation
import ImageCaptureCore

final class Probe: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    let browser = ICDeviceBrowser()
    let shoot: Bool
    let outDir: URL
    var shot = false
    var known = Set<String>()

    init(shoot: Bool, outDir: URL) {
        self.shoot = shoot
        self.outDir = outDir
    }

    func start() {
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        browser.start()
        print("looking for cameras…")
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        print("found:", device.name ?? "?", "| transport:", device.transportType ?? "?", "| type:", device.type.rawValue)
        guard let camera = device as? ICCameraDevice else { return }
        camera.delegate = self
        camera.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        print("removed:", device.name ?? "?")
    }

    func didRemove(_ device: ICDevice) {}

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        print("session open:", error?.localizedDescription ?? "ok")
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        let files = device.mediaFiles ?? []
        print("ready. capabilities:", device.capabilities)
        print("can take picture:", device.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue))
        print("files on camera:", files.count)
        for file in files.suffix(6) {
            if let f = file as? ICCameraFile {
                print("  ", f.name ?? "?", f.fileSize, f.creationDate.map { "\($0)" } ?? "")
            }
        }
        known = Set(files.compactMap { $0.name })
        if shoot, !shot, device.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue) {
            shot = true
            print("firing the shutter…")
            device.requestTakePicture()
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        for item in items {
            guard let file = item as? ICCameraFile, let name = file.name, shot, !known.contains(name) else { continue }
            known.insert(name)
            print("new frame on camera:", name, file.fileSize)
            camera.requestDownloadFile(file, options: [.downloadsDirectoryURL: outDir], downloadDelegate: self,
                                       didDownloadSelector: #selector(didDownload(_:error:options:contextInfo:)), contextInfo: nil)
        }
    }

    @objc func didDownload(_ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        print("downloaded:", file.name ?? "?", error?.localizedDescription ?? "ok", options[ICDownloadOption.savedFilename.rawValue] ?? "")
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        print("capabilities changed:", camera.capabilities)
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        print("PTP event:", eventData.map { String(format: "%02x", $0) }.joined().prefix(48))
    }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

let args = Array(CommandLine.arguments.dropFirst())
let wantsShot = args.contains("shoot")
let dir = URL(fileURLWithPath: args.first { $0 != "shoot" } ?? NSTemporaryDirectory())
let probe = Probe(shoot: wantsShot, outDir: dir)
probe.start()
RunLoop.main.run(until: Date().addingTimeInterval(wantsShot ? 40 : 15))
print("done")
