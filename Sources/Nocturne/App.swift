// Nocturne: app entry. One opaque window that shows the library or the editor, plus the menu commands.
import NocturneKit
import SwiftUI

@main
struct NocturneApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Nocturne", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 660)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Photo") {
                Button("Describe the Look") { model.focusPrompt += 1 }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.current == nil)
                Button("Presets") { model.presetsOpen.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.current == nil)
                Button("Export…") { model.beginExport() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.current == nil)
                Divider()
                Button("Copy Look") { model.copyLook() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Paste Look") { model.pasteLook() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(!model.hasCopiedLook)
                Button("Match Pasted Image") { model.pasteReference() }
                    .disabled(model.current == nil)
                Menu("Apply Preset") {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.usePreset(preset) }
                    }
                }
                .disabled(model.presets.isEmpty)
                Divider()
                Button("Select All Photos") { model.selectAll() }
                    .disabled(model.current != nil)
                Button("Export Selected Photos") { model.exportSelection() }
                    .disabled(model.current != nil)
                Divider()
                Button("Back to Library") { model.closeEditor() }
                    .disabled(model.current == nil)
                Button("Show Folder in Finder") { model.showInFinder(nil) }
                Divider()
                Menu("AI Model") {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Button((model.aiProvider == provider ? "✓ " : "   ") + provider.title) { model.setProvider(provider) }
                    }
                }
                Button("Field Guide") { model.guideOpen.toggle() }
                    .disabled(model.current != nil)
                Button(model.night ? "Turn Night Mode Off" : "Night Mode") { model.night.toggle() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            if model.current != nil {
                EditorView()
            } else {
                LibraryView()
            }
        }
        .background(Color.black)
        .overlay {
            if model.night {
                NightTint().allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}
