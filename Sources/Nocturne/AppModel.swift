// Nocturne: app state. Library shelves, the open photo, its recipe with undo, AI calls and export.
import AppKit
import CoreImage
import NocturneKit
import SwiftUI

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

@MainActor
final class AppModel: ObservableObject {
    let engine = Engine.shared
    let library = Library()
    let thumbs: ThumbnailStore
    let ai = Gemini()

    @Published var shelf: Shelf = .toProcess
    @Published var photos: [Photo] = []
    @Published var counts: [Shelf: Int] = [:]
    @Published var selection: String?
    @Published var thumbEpoch = 0
    @Published var scanned = false

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
    @Published var notice: Notice?
    @Published var exportDraft: ExportDraft?

    var columns = 5
    private(set) var display: CIImage?
    private var source: SourceImage?
    private var undoStack: [Recipe] = []
    private var redoStack: [Recipe] = []
    private var editStart: Recipe?
    private var dirty = false
    private var saveWork: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?
    private var loadID = 0
    private var monitor: Any?

    init() {
        thumbs = ThumbnailStore(engine: engine, library: library)
        try? library.prepare()
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
                if self.selection == nil || !list.contains(where: { $0.id == self.selection }) {
                    self.selection = list.first?.id
                }
            }
        }
    }

    func switchShelf(_ next: Shelf) {
        guard next != shelf else { return }
        shelf = next
        photos = []
        selection = nil
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

    func trash(_ photo: Photo) {
        do {
            try library.trash(photo)
            reload()
        } catch {
            say("Could not move the photo to the Trash.", error: true)
        }
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
    }

    func openSelected() {
        if let photo = photos.first(where: { $0.id == selection }) { open(photo) }
    }

    func open(_ photo: Photo) {
        leavePhoto()
        current = photo
        selection = photo.id
        recipe = library.loadRecipe(for: photo)
        undoStack = []
        redoStack = []
        editStart = nil
        selectedStep = nil
        showOriginal = false
        exportDraft = nil
        prompt = ""
        source = nil
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
        let image = engine.render(source.image, recipe: recipe)
        let engine = engine
        let thumbs = thumbs
        Task.detached(priority: .utility) {
            if let cg = engine.cgImage(image, maxEdge: ThumbnailStore.edge) {
                thumbs.store(cg, for: photo)
                await MainActor.run { self.thumbEpoch += 1 }
            }
        }
    }

    func closeEditor() {
        leavePhoto()
        loadID += 1
        current = nil
        source = nil
        display = nil
        exportDraft = nil
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
        display = showOriginal ? source.image : engine.render(source.image, recipe: recipe)
        renderToken += 1
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
        if let existing = recipe.steps.last(where: { $0.kind == kind && !$0.ai }) {
            selectedStep = selectedStep == existing.id ? nil : existing.id
            return
        }
        let step = Step(kind: kind)
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
        let ai = ai
        let base = source.image
        Task {
            do {
                let preview = await Task.detached(priority: .userInitiated) {
                    engine.jpegData(engine.render(base, recipe: manual), maxEdge: 768, quality: 0.8)
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

    func beginExport() {
        guard let photo = current, let source, exportDraft == nil else { return }
        let base = photo.url.deletingPathExtension().lastPathComponent
        if photo.shelf == .processed {
            exportDraft = ExportDraft(name: base, suggesting: false, touched: true, working: false, renamable: false)
            return
        }
        exportDraft = ExportDraft(name: base, suggesting: true, touched: false, working: false, renamable: true)
        let image = engine.render(source.image, recipe: recipe)
        let engine = engine
        let ai = ai
        Task {
            let preview = await Task.detached(priority: .userInitiated) {
                engine.jpegData(image, maxEdge: 512, quality: 0.75)
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
        let image = engine.render(source.image, recipe: recipe)
        let props = source.properties
        let lib = library
        let engine = engine
        let index = photos.firstIndex { $0.id == photo.id }
        Task {
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                Result { try lib.export(photo: photo, recipe: recipe, name: name, image: image, properties: props, engine: engine) }
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
        let typing = (e.window ?? NSApp.keyWindow)?.firstResponder is NSTextView
        if typing {
            if e.keyCode == 53 {
                NSApp.keyWindow?.makeFirstResponder(nil)
                if exportDraft != nil { exportDraft = nil }
                return true
            }
            return false
        }
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) { return false }
        if current != nil {
            switch e.keyCode {
            case 53:
                if exportDraft != nil { exportDraft = nil } else { closeEditor() }
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
