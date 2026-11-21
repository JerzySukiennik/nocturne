// Nocturne: app state. Library shelves and selection, the open photo, its recipe with undo, masks, presets, batch work, AI calls and export.
import AppKit
import CoreImage
import NocturneKit
import SwiftUI
import UniformTypeIdentifiers

struct ExportDraft: Equatable {
    var name: String
    var suggesting: Bool
    var touched: Bool
    var working: Bool
    var renamable: Bool
}

struct Notice: Equatable {
    var text: String
    var isError: Bool
}

struct BatchProgress: Equatable {
    var label: String
    var done: Int
    var total: Int
}

@MainActor
final class AppModel: ObservableObject {
    let engine = Engine.shared
    let library = Library()
    let masker: Masker
    let thumbs: ThumbnailStore
    let ai = Gemini()

    @Published var shelf: Shelf = .toProcess
    @Published var photos: [Photo] = []
    @Published var counts: [Shelf: Int] = [:]
    @Published var selection: String?
    @Published var selected: Set<String> = []
    @Published var thumbEpoch = 0
    @Published var scanned = false
    @Published var batch: BatchProgress?

    @Published var current: Photo?
    @Published var recipe = Recipe()
    @Published var selectedStep: UUID?
    @Published var loading = false
    @Published var showOriginal = false
    @Published var controlsHidden = false
    @Published var renderToken = 0
    @Published var zoomToggle = 0
    @Published var prompt = ""
    @Published var focusPrompt = 0
    @Published var aiBusy = false
    @Published var maskBusy = false
    @Published var notice: Notice?
    @Published var exportDraft: ExportDraft?
    @Published var presets: [Preset] = []
    @Published var presetsOpen = false
    @Published var presetName = ""
    @Published var hasCopiedLook = false

    var columns = 5
    private(set) var display: CIImage?
    private var source: SourceImage?
    private var masks = MaskSet()
    private var maskFailed: Set<MaskKind> = []
    private var depthFailed = false
    private var maskPreview: MaskKind?
    private var previewRecipe: Recipe?
    private var copiedLook: Recipe?
    private var undoStack: [Recipe] = []
    private var redoStack: [Recipe] = []
    private var editStart: Recipe?
    private var dirty = false
    private var saveWork: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?
    private var loadID = 0
    private var monitor: Any?

    init() {
        masker = Masker(engine: engine)
        thumbs = ThumbnailStore(engine: engine, library: library, masker: masker)
        try? library.prepare()
        presets = library.presets()
        reload()
        library.watch { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleKey(event) }
            return handled ? nil : event
        }
    }

    func reload() {
        let lib = library
        let shelf = shelf
        Task.detached(priority: .userInitiated) {
            let list = lib.scan(shelf)
            var counts: [Shelf: Int] = [:]
            for s in Shelf.allCases { counts[s] = s == shelf ? list.count : lib.count(s) }
            let result = counts
            await MainActor.run {
                guard self.shelf == shelf else { return }
                self.photos = list
                self.counts = result
                self.scanned = true
                let ids = Set(list.map { $0.id })
                if self.selection == nil || !ids.contains(self.selection ?? "") {
                    self.selection = list.first?.id
                }
                self.selected = self.selected.intersection(ids)
                if self.selected.isEmpty, let primary = self.selection { self.selected = [primary] }
            }
        }
    }

    func switchShelf(_ next: Shelf) {
        guard next != shelf else { return }
        shelf = next
        photos = []
        selection = nil
        selected = []
        reload()
    }

    func importDropped(_ urls: [URL]) {
        let lib = library
        Task.detached {
            let n = lib.importFiles(urls)
            await MainActor.run {
                if n > 0 {
                    self.say("Added \(n) photo\(n == 1 ? "" : "s") to To Process.", error: false)
                    if self.shelf != .toProcess { self.switchShelf(.toProcess) } else { self.reload() }
                }
            }
        }
    }

    var targets: [Photo] {
        photos.filter { selected.contains($0.id) }
    }

    func click(_ photo: Photo) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selected.contains(photo.id), selected.count > 1 {
                selected.remove(photo.id)
                if selection == photo.id { selection = selected.first }
            } else {
                selected.insert(photo.id)
                selection = photo.id
            }
        } else if flags.contains(.shift), let anchor = photos.firstIndex(where: { $0.id == selection }),
                  let end = photos.firstIndex(where: { $0.id == photo.id }) {
            selected = Set(photos[min(anchor, end)...max(anchor, end)].map { $0.id })
        } else {
            selection = photo.id
            selected = [photo.id]
        }
    }

    func focus(_ photo: Photo, keepSelection: Bool) {
        if keepSelection && selected.contains(photo.id) { return }
        selection = photo.id
        selected = [photo.id]
    }

    func selectAll() {
        selected = Set(photos.map { $0.id })
        if selection == nil { selection = photos.first?.id }
    }

    func trashSelection(including photo: Photo) {
        let list = selected.contains(photo.id) ? targets : [photo]
        var failed = 0
        for item in list {
            if (try? library.trash(item)) == nil { failed += 1 }
        }
        if failed > 0 { say("Could not move \(failed) photo\(failed == 1 ? "" : "s") to the Trash.", error: true) }
        reload()
    }

    func showInFinder(_ photo: Photo?) {
        if let photo {
            NSWorkspace.shared.activateFileViewerSelecting([photo.url])
        } else {
            NSWorkspace.shared.open(library.folder(shelf))
        }
    }

    func moveSelection(_ delta: Int) {
        guard !photos.isEmpty else { return }
        let index = photos.firstIndex { $0.id == selection } ?? 0
        let next = min(max(index + delta, 0), photos.count - 1)
        selection = photos[next].id
        selected = [photos[next].id]
    }

    func openSelected() {
        if let photo = photos.first(where: { $0.id == selection }) { open(photo) }
    }

    func open(_ photo: Photo) {
        leavePhoto()
        current = photo
        selection = photo.id
        selected = [photo.id]
        recipe = library.loadRecipe(for: photo)
        undoStack = []
        redoStack = []
        editStart = nil
        selectedStep = nil
        showOriginal = false
        exportDraft = nil
        presetsOpen = false
        prompt = ""
        source = nil
        masks = MaskSet()
        maskFailed = []
        depthFailed = false
        maskPreview = nil
        previewRecipe = nil
        maskBusy = false
        if let thumb = thumbs.cached(photo) {
            display = CIImage(cgImage: thumb)
        } else {
            display = nil
        }
        renderToken += 1
        loading = true
        loadID += 1
        let id = loadID
        let url = library.sourceURL(for: photo)
        let engine = engine
        Task.detached(priority: .userInitiated) {
            let loaded = try? engine.load(url)
            await MainActor.run {
                guard self.loadID == id else { return }
                self.loading = false
                guard let loaded else {
                    self.say("Could not open this photo.", error: true)
                    return
                }
                self.source = loaded
                self.refresh()
            }
        }
    }

    private func leavePhoto() {
        guard let photo = current else { return }
        let changed = dirty
        flushSave()
        guard changed, photo.shelf == .toProcess, let source else { return }
        let engine = engine
        let masker = masker
        let thumbs = thumbs
        let recipe = recipe
        let masks = masks
        Task.detached(priority: .utility) {
            let image = AppModel.finalImage(engine: engine, masker: masker, source: source, recipe: recipe, masks: masks)
            if let cg = engine.cgImage(image, maxEdge: ThumbnailStore.edge) {
                thumbs.store(cg, for: photo)
                await MainActor.run { self.thumbEpoch += 1 }
            }
        }
    }

    nonisolated private static func finalImage(engine: Engine, masker: Masker, source: SourceImage, recipe: Recipe, masks: MaskSet) -> CIImage {
        masker.prepare(recipe, source: source.image, into: masks)
        return engine.render(source.image, recipe: recipe, masks: masks)
    }

    func closeEditor() {
        leavePhoto()
        loadID += 1
        current = nil
        source = nil
        display = nil
        exportDraft = nil
        presetsOpen = false
        previewRecipe = nil
        maskPreview = nil
        loading = false
        reload()
    }

    func step(_ delta: Int) {
        guard let photo = current, let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        let next = index + delta
        guard photos.indices.contains(next) else { return }
        open(photos[next])
    }

    var position: String {
        guard let photo = current, let index = photos.firstIndex(where: { $0.id == photo.id }) else { return "" }
        return "\(index + 1) / \(photos.count)"
    }

    func refresh() {
        guard let source else { return }
        if showOriginal {
            display = source.image
        } else {
            var image = engine.render(source.image, recipe: previewRecipe ?? recipe, masks: masks)
            if let kind = maskPreview, let mask = masks.image(kind) {
                let tint = CIImage(color: CIColor(red: 0.95, green: 0.85, blue: 0.54, alpha: 0.62)).cropped(to: image.extent)
                image = tint.composited(over: image).applyingFilter("CIBlendWithRedMask", parameters: [
                    kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask
                ])
            }
            if previewRecipe == nil, let id = selectedStep, let step = recipe.steps.first(where: { $0.id == id }), step.kind == .lamp, step.on {
                let e = image.extent
                let center = CGPoint(x: step.value("x") / 100 * e.width, y: (1 - step.value("y") / 100) * e.height)
                image = AppModel.marker(at: center, radius: max(e.width, e.height) * 0.011, extent: e).composited(over: image)
            }
            display = image
        }
        renderToken += 1
        ensureMasks()
    }

    private static func marker(at center: CGPoint, radius: CGFloat, extent: CGRect) -> CIImage {
        func ring(_ inner: CGFloat, _ outer: CGFloat, _ color: CIColor) -> CIImage {
            CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(cgPoint: center), "inputRadius0": inner, "inputRadius1": outer,
                "inputColor0": color, "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            ])?.outputImage?.cropped(to: extent) ?? CIImage.empty()
        }
        let halo = ring(radius * 1.0, radius * 1.7, CIColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        let dot = ring(radius * 0.6, radius * 0.95, CIColor(red: 1.0, green: 0.93, blue: 0.7, alpha: 1))
        return dot.composited(over: halo)
    }

    func canvasPoint(_ p: CGPoint, phase: Int) -> Bool {
        guard !showOriginal, let id = selectedStep, let i = recipe.steps.firstIndex(where: { $0.id == id }) else { return false }
        let x = min(max(Double(p.x), 0), 1)
        let yTop = min(max(1 - Double(p.y), 0), 1)
        switch recipe.steps[i].kind {
        case .lamp:
            if phase == 0 { beginEdit() }
            recipe.steps[i].params["x"] = x * 100
            recipe.steps[i].params["y"] = yTop * 100
            if phase == 2 { endEdit() }
            refresh()
            return true
        case .bokeh:
            guard let d = masks.depthValue(x: x, yFromTop: yTop) else { return true }
            if phase == 0 { beginEdit() }
            recipe.steps[i].params["focus"] = d * 100
            if phase == 2 { endEdit() }
            refresh()
            return true
        default:
            return false
        }
    }

    private func ensureMasks() {
        guard let source, let photo = current, !maskBusy else { return }
        let active = previewRecipe ?? recipe
        var needed = active.maskKinds
        if let kind = maskPreview { needed.insert(kind) }
        needed.subtract(masks.ready)
        needed.subtract(maskFailed)
        let wantDepth = active.needsDepth && masks.depth == nil && !depthFailed
        guard !needed.isEmpty || wantDepth else { return }
        maskBusy = true
        let masker = masker
        let masks = masks
        let wanted = needed
        Task.detached(priority: .userInitiated) {
            masker.compute(wanted, depth: wantDepth, source: source.image, into: masks)
            await MainActor.run {
                guard self.current?.id == photo.id, self.masks === masks else { return }
                self.maskBusy = false
                let missing = wanted.subtracting(masks.ready)
                if wantDepth && masks.depth == nil { self.depthFailed = true }
                if !missing.isEmpty || self.depthFailed {
                    self.maskFailed.formUnion(missing)
                    self.say("The depth model is missing, so depth masks, lamps and lens blur are off.", error: true)
                }
                self.refresh()
            }
        }
    }

    func previewMask(_ kind: MaskKind?) {
        guard maskPreview != kind else { return }
        maskPreview = kind
        refresh()
    }

    func setMask(_ id: UUID, _ kind: MaskKind?) {
        mutate { r in
            if let i = r.steps.firstIndex(where: { $0.id == id }) { r.steps[i].mask = kind }
        }
    }

    func beginEdit() {
        if editStart == nil { editStart = recipe }
    }

    func endEdit() {
        if let start = editStart, start != recipe {
            undoStack.append(start)
            if undoStack.count > 100 { undoStack.removeFirst() }
            redoStack = []
            dirty = true
            saveSoon()
        }
        editStart = nil
    }

    func mutate(_ change: (inout Recipe) -> Void) {
        beginEdit()
        change(&recipe)
        endEdit()
        refresh()
    }

    func setParam(_ id: UUID, _ key: String, _ value: Double) {
        guard let i = recipe.steps.firstIndex(where: { $0.id == id }) else { return }
        recipe.steps[i].params[key] = value
        refresh()
    }

    func toggle(_ id: UUID) {
        mutate { r in
            if let i = r.steps.firstIndex(where: { $0.id == id }) { r.steps[i].on.toggle() }
        }
    }

    func delete(_ id: UUID) {
        mutate { r in r.steps.removeAll { $0.id == id } }
        if selectedStep == id { selectedStep = nil }
    }

    func focusTool(_ kind: StepKind) {
        let addAnother = kind == .lamp && recipe.steps.contains { $0.id == selectedStep && $0.kind == .lamp }
        if !addAnother, let existing = recipe.steps.last(where: { $0.kind == kind && !$0.ai && $0.mask == nil }) {
            selectedStep = selectedStep == existing.id ? nil : existing.id
            return
        }
        var step = Step(kind: kind)
        if addAnother {
            step.name = "Lamp \(recipe.steps.filter { $0.kind == .lamp }.count + 1)"
            step.params["x"] = 70
            step.params["warmth"] = -30
        }
        mutate { r in
            let firstAI = r.steps.firstIndex { $0.ai } ?? r.steps.count
            r.steps.insert(step, at: firstAI)
        }
        selectedStep = step.id
    }

    func undo() {
        guard current != nil, let last = undoStack.popLast() else { return }
        redoStack.append(recipe)
        recipe = last
        afterHistoryJump()
    }

    func redo() {
        guard current != nil, let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        recipe = next
        afterHistoryJump()
    }

    private func afterHistoryJump() {
        if let id = selectedStep, !recipe.steps.contains(where: { $0.id == id }) { selectedStep = nil }
        dirty = true
        saveSoon()
        refresh()
    }

    private func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushSave() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        guard dirty, let photo = current else { return }
        library.saveRecipe(recipe, for: photo)
        dirty = false
    }

    func say(_ text: String, error: Bool) {
        notice = Notice(text: text, isError: error)
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.notice = nil }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 9 : 6), execute: work)
    }

    func describe() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !aiBusy, let source, let photo = current else { return }
        aiBusy = true
        notice = nil
        let manual = recipe.manual
        let previous = recipe.steps.filter { $0.ai }
        let engine = engine
        let masker = masker
        let masks = masks
        let ai = ai
        Task {
            do {
                let preview = await Task.detached(priority: .userInitiated) {
                    let image = AppModel.finalImage(engine: engine, masker: masker, source: source, recipe: manual, masks: masks)
                    return engine.jpegData(image, maxEdge: 768, quality: 0.8)
                }.value
                guard let preview else { throw AIError.badAnswer }
                let answer = try await ai.describeLook(prompt: text, preview: preview, previous: previous)
                if self.current?.id == photo.id {
                    let kept = self.recipe.manual.steps
                    self.mutate { r in r.steps = kept + answer.steps }
                    self.selectedStep = nil
                    self.prompt = ""
                    self.say(answer.note.isEmpty ? "Look applied." : answer.note, error: false)
                }
            } catch {
                self.say((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, error: true)
            }
            self.aiBusy = false
        }
    }

    private var clipboardImage: CGImage? {
        let pb = NSPasteboard.general
        guard pb.canReadObject(forClasses: [NSImage.self], options: nil), let image = NSImage(pasteboard: pb) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    @discardableResult
    func pasteReference() -> Bool {
        guard let source, let photo = current, let cg = clipboardImage else { return false }
        let reference = CIImage(cgImage: cg)
        let rest = Recipe(steps: recipe.steps.filter { $0.kind != .match })
        let engine = engine
        let masker = masker
        let masks = masks
        Task {
            let step = await Task.detached(priority: .userInitiated) { () -> Step? in
                let now = AppModel.finalImage(engine: engine, masker: masker, source: source, recipe: rest, masks: masks)
                guard var step = engine.matchStep(reference: reference, current: now) else { return nil }
                step.params["amount"] = 80
                return step
            }.value
            guard self.current?.id == photo.id else { return }
            guard let step else {
                self.say("Could not read the pasted image.", error: true)
                return
            }
            self.mutate { r in
                r.steps.removeAll { $0.kind == .match }
                r.steps.append(step)
            }
            self.selectedStep = step.id
            self.say("Matched the pasted reference. Tune it with Amount.", error: false)
        }
        return true
    }

    func savePreset() {
        let name = Library.cleanName(presetName)
        guard !name.isEmpty, recipe.hasEffect else { return }
        do {
            try library.savePreset(name: name, recipe: recipe)
            presets = library.presets()
            presetName = ""
            say("Saved preset \(name).", error: false)
        } catch {
            say("Could not save the preset.", error: true)
        }
    }

    func deletePreset(_ preset: Preset) {
        library.deletePreset(preset.name)
        presets = library.presets()
    }

    func previewPreset(_ preset: Preset?) {
        guard let source else { return }
        let next = preset.map { engine.adapted($0.recipe, to: source.image, masks: masks) }
        if next == nil && previewRecipe == nil { return }
        previewRecipe = next
        refresh()
    }

    func applyPreset(_ preset: Preset) {
        guard let source else { return }
        let adapted = engine.adapted(preset.recipe, to: source.image, masks: masks)
        previewRecipe = nil
        mutate { r in r = adapted }
        selectedStep = nil
        presetsOpen = false
        say("Applied \(preset.name).", error: false)
    }

    func usePreset(_ preset: Preset) {
        if current != nil {
            applyPreset(preset)
        } else {
            applyToSelection(preset.recipe, label: "Applying \(preset.name)")
        }
    }

    func copyLook() {
        if current != nil {
            copiedLook = recipe
        } else if let photo = photos.first(where: { $0.id == selection }) {
            copiedLook = library.loadRecipe(for: photo)
        }
        hasCopiedLook = copiedLook?.hasEffect ?? false
        say(hasCopiedLook ? "Look copied." : "This photo has no look to copy.", error: !hasCopiedLook)
    }

    func pasteLook() {
        guard let look = copiedLook, look.hasEffect else { return }
        if let source, current != nil {
            let adapted = engine.adapted(look, to: source.image, masks: masks)
            mutate { r in r = adapted }
            selectedStep = nil
            return
        }
        applyToSelection(look, label: "Applying look")
    }

    func applyToSelection(_ look: Recipe, label: String) {
        let list = targets.filter { $0.shelf == .toProcess }
        guard !list.isEmpty, batch == nil else { return }
        batch = BatchProgress(label: label, done: 0, total: list.count)
        let lib = library
        let engine = engine
        let masker = masker
        let needsSource = look.steps.contains { $0.kind == .match }
        Task.detached(priority: .userInitiated) {
            for (i, photo) in list.enumerated() {
                var recipe = look.fresh()
                if needsSource, let source = try? engine.load(photo.url) {
                    let masks = MaskSet()
                    masker.prepare(look, source: source.image, into: masks)
                    recipe = engine.adapted(look, to: source.image, masks: masks)
                }
                lib.saveRecipe(recipe, for: photo)
                await MainActor.run { self.batch?.done = i + 1 }
            }
            await MainActor.run {
                self.batch = nil
                self.thumbEpoch += 1
                self.reload()
                self.say("Look applied to \(list.count) photo\(list.count == 1 ? "" : "s").", error: false)
            }
        }
    }

    func exportSelection() {
        let list = targets.filter { $0.shelf == .toProcess }
        guard !list.isEmpty, batch == nil else { return }
        batch = BatchProgress(label: "Exporting", done: 0, total: list.count)
        let lib = library
        let engine = engine
        let masker = masker
        let ai = ai
        Task.detached(priority: .userInitiated) {
            var failed = 0
            for (i, photo) in list.enumerated() {
                do {
                    let source = try engine.load(photo.url)
                    let recipe = lib.loadRecipe(for: photo)
                    let image = AppModel.finalImage(engine: engine, masker: masker, source: source, recipe: recipe, masks: MaskSet())
                    var name = photo.url.deletingPathExtension().lastPathComponent
                    if let preview = engine.jpegData(image, maxEdge: 512, quality: 0.75), let suggestion = try? await ai.suggestName(preview: preview) {
                        name = suggestion
                    }
                    _ = try lib.export(photo: photo, recipe: recipe, name: name, image: image, properties: source.properties, engine: engine)
                } catch {
                    failed += 1
                }
                await MainActor.run { self.batch?.done = i + 1 }
            }
            let bad = failed
            await MainActor.run {
                self.batch = nil
                self.reload()
                let ok = list.count - bad
                self.say(bad == 0 ? "Exported \(ok) photo\(ok == 1 ? "" : "s") to Processed." : "Exported \(ok), \(bad) failed.", error: bad > 0)
            }
        }
    }

    func beginExport() {
        guard let photo = current, let source, exportDraft == nil else { return }
        presetsOpen = false
        let base = photo.url.deletingPathExtension().lastPathComponent
        if photo.shelf == .processed {
            exportDraft = ExportDraft(name: base, suggesting: false, touched: true, working: false, renamable: false)
            return
        }
        exportDraft = ExportDraft(name: base, suggesting: true, touched: false, working: false, renamable: true)
        let engine = engine
        let masker = masker
        let masks = masks
        let recipe = recipe
        let ai = ai
        Task {
            let preview = await Task.detached(priority: .userInitiated) {
                let image = AppModel.finalImage(engine: engine, masker: masker, source: source, recipe: recipe, masks: masks)
                return engine.jpegData(image, maxEdge: 512, quality: 0.75)
            }.value
            var suggestion: String?
            if let preview { suggestion = try? await ai.suggestName(preview: preview) }
            guard var draft = self.exportDraft, self.current?.id == photo.id else { return }
            draft.suggesting = false
            if let suggestion, !draft.touched { draft.name = suggestion }
            self.exportDraft = draft
        }
    }

    func confirmExport() {
        guard let photo = current, let source, var draft = exportDraft, !draft.working else { return }
        draft.working = true
        exportDraft = draft
        flushSave()
        let recipe = recipe
        let name = draft.name
        let lib = library
        let engine = engine
        let masker = masker
        let masks = masks
        let index = photos.firstIndex { $0.id == photo.id }
        Task {
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let image = AppModel.finalImage(engine: engine, masker: masker, source: source, recipe: recipe, masks: masks)
                    return try lib.export(photo: photo, recipe: recipe, name: name, image: image, properties: source.properties, engine: engine)
                }
            }.value
            switch result {
            case .success(let url):
                self.exportDraft = nil
                self.dirty = false
                var next: Photo?
                if photo.shelf == .toProcess, let index {
                    let rest = self.photos.filter { $0.id != photo.id }
                    if !rest.isEmpty { next = rest[min(index, rest.count - 1)] }
                    self.photos = rest
                }
                self.loadID += 1
                self.current = nil
                self.source = nil
                self.display = nil
                self.thumbEpoch += 1
                if let next { self.open(next) }
                self.reload()
                self.say("Exported \(url.lastPathComponent)", error: false)
            case .failure(let error):
                draft.working = false
                self.exportDraft = draft
                self.say("Export failed: \(error.localizedDescription)", error: true)
            }
        }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        if e.type == .keyUp {
            if e.keyCode == 42, showOriginal {
                showOriginal = false
                refresh()
                return true
            }
            return false
        }
        let command = e.modifierFlags.contains(.command)
        let shift = e.modifierFlags.contains(.shift)
        if command, !shift, e.keyCode == 9, current != nil, clipboardImage != nil {
            pasteReference()
            return true
        }
        let typing = (e.window ?? NSApp.keyWindow)?.firstResponder is NSTextView
        if typing {
            if e.keyCode == 53 {
                (e.window ?? NSApp.keyWindow)?.makeFirstResponder(nil)
                if exportDraft != nil { exportDraft = nil }
                return true
            }
            return false
        }
        if command, !shift, e.keyCode == 0, current == nil {
            selectAll()
            return true
        }
        if command || e.modifierFlags.contains(.control) { return false }
        if current != nil {
            switch e.keyCode {
            case 53:
                if exportDraft != nil {
                    exportDraft = nil
                } else if presetsOpen {
                    presetsOpen = false
                    previewPreset(nil)
                } else {
                    closeEditor()
                }
            case 123: step(-1)
            case 124: step(1)
            case 42:
                if !e.isARepeat, source != nil {
                    showOriginal = true
                    refresh()
                }
            case 48: controlsHidden.toggle()
            case 51:
                if let id = selectedStep { delete(id) }
            case 6: zoomToggle += 1
            case 36:
                if exportDraft != nil {
                    confirmExport()
                } else if prompt.trimmingCharacters(in: .whitespaces).isEmpty {
                    focusPrompt += 1
                } else {
                    describe()
                }
            default: return false
            }
            return true
        }
        switch e.keyCode {
        case 123: moveSelection(-1)
        case 124: moveSelection(1)
        case 125: moveSelection(columns)
        case 126: moveSelection(-columns)
        case 36, 49: openSelected()
        default: return false
        }
        return true
    }
}
