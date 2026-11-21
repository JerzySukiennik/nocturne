// Nocturne: the photo canvas. A Metal view that draws only when the image or the zoom changes.
import CoreImage
import MetalKit
import NocturneKit
import SwiftUI

final class CanvasView: MTKView, MTKViewDelegate {
    private let engine: Engine
    private let queue: MTLCommandQueue?
    private let space = CGColorSpace(name: CGColorSpace.displayP3)!
    private var zoom: CGFloat = 0
    private var center = CGPoint(x: 0.5, y: 0.5)
    private var extent = CGRect.zero
    var token = -1
    var zoomToken = 0

    var image: CIImage? {
        didSet {
            let next = image?.extent ?? .zero
            if abs(next.width / max(next.height, 1) - extent.width / max(extent.height, 1)) > 0.01 {
                zoom = 0
                center = CGPoint(x: 0.5, y: 0.5)
            } else if zoom > 0, extent.width > 0, next.width > 0 {
                zoom *= extent.width / next.width
            }
            extent = next
            needsDisplay = true
        }
    }

    init(engine: Engine) {
        self.engine = engine
        queue = engine.device.makeCommandQueue()
        super.init(frame: .zero, device: engine.device)
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm
        colorspace = space
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        delegate = self
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    private func layout(_ size: CGSize) -> (scale: CGFloat, tx: CGFloat, ty: CGFloat, fit: CGFloat) {
        let fit = min(size.width / max(extent.width, 1), size.height / max(extent.height, 1))
        let s = zoom > 0 ? zoom : fit
        let w = extent.width * s
        let h = extent.height * s
        var tx = size.width / 2 - center.x * w
        var ty = size.height / 2 - center.y * h
        tx = w <= size.width ? (size.width - w) / 2 : min(0, max(size.width - w, tx))
        ty = h <= size.height ? (size.height - h) / 2 : min(0, max(size.height - h, ty))
        return (s, tx, ty, fit)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable, let buffer = queue?.makeCommandBuffer() else { return }
        let size = drawableSize
        let bounds = CGRect(origin: .zero, size: size)
        let destination = CIRenderDestination(
            width: Int(size.width), height: Int(size.height),
            pixelFormat: colorPixelFormat, commandBuffer: buffer
        ) { drawable.texture }
        destination.colorSpace = space
        var out = CIImage(color: CIColor.black).cropped(to: bounds)
        if let image, extent.width > 0 {
            let l = layout(size)
            let t = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: l.scale, y: l.scale))
                .concatenating(CGAffineTransform(translationX: l.tx.rounded(), y: l.ty.rounded()))
            out = image.transformed(by: t).composited(over: out)
        }
        _ = try? engine.context.startTask(toRender: out, from: bounds, to: destination, at: .zero)
        buffer.present(drawable)
        buffer.commit()
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let p = convertToBacking(convert(event.locationInWindow, from: nil))
        let l = layout(drawableSize)
        let w = max(extent.width * l.scale, 1)
        let h = max(extent.height * l.scale, 1)
        return CGPoint(x: (p.x - l.tx) / w, y: (p.y - l.ty) / h)
    }

    private func setZoom(_ next: CGFloat, anchor: CGPoint, at cursor: CGPoint) {
        let size = drawableSize
        let fit = layout(size).fit
        if next <= fit * 1.02 {
            zoom = 0
            center = CGPoint(x: 0.5, y: 0.5)
        } else {
            zoom = min(next, 8)
            let w = extent.width * zoom
            let h = extent.height * zoom
            center = CGPoint(
                x: anchor.x + (size.width / 2 - cursor.x) / w,
                y: anchor.y + (size.height / 2 - cursor.y) / h
            )
        }
        needsDisplay = true
    }

    func toggleZoom(at event: NSEvent?) {
        guard extent.width > 0 else { return }
        if zoom > 0 {
            zoom = 0
            center = CGPoint(x: 0.5, y: 0.5)
            needsDisplay = true
            return
        }
        let size = drawableSize
        var anchor = CGPoint(x: 0.5, y: 0.5)
        var cursor = CGPoint(x: size.width / 2, y: size.height / 2)
        if let event {
            anchor = imagePoint(event)
            cursor = convertToBacking(convert(event.locationInWindow, from: nil))
        }
        setZoom(1, anchor: anchor, at: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)
        if event.clickCount == 2 { toggleZoom(at: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        pan(dx: event.deltaX, dy: -event.deltaY)
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoom > 0 else { return }
        pan(dx: event.scrollingDeltaX, dy: -event.scrollingDeltaY)
    }

    override func magnify(with event: NSEvent) {
        guard extent.width > 0 else { return }
        let l = layout(drawableSize)
        let anchor = imagePoint(event)
        let cursor = convertToBacking(convert(event.locationInWindow, from: nil))
        setZoom(l.scale * (1 + event.magnification), anchor: anchor, at: cursor)
    }

    private func pan(dx: CGFloat, dy: CGFloat) {
        guard zoom > 0 else { return }
        let k = window?.backingScaleFactor ?? 2
        let w = max(extent.width * zoom, 1)
        let h = max(extent.height * zoom, 1)
        let size = drawableSize
        let halfX = min(0.5, size.width / (2 * w))
        let halfY = min(0.5, size.height / (2 * h))
        center.x = min(max(center.x - dx * k / w, halfX), 1 - halfX)
        center.y = min(max(center.y - dy * k / h, halfY), 1 - halfY)
        needsDisplay = true
    }
}

struct Canvas: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> CanvasView {
        CanvasView(engine: model.engine)
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        if view.token != model.renderToken {
            view.token = model.renderToken
            view.image = model.display
        }
        if view.zoomToken != model.zoomToggle {
            view.zoomToken = model.zoomToggle
            view.toggleZoom(at: nil)
        }
    }
}
