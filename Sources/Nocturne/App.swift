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
                Button("Export…") { model.beginExport() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.current == nil)
                Divider()
                Button("Back to Library") { model.closeEditor() }
                    .disabled(model.current == nil)
                Button("Show Folder in Finder") { model.showInFinder(nil) }
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
        .ignoresSafeArea()
    }
}
