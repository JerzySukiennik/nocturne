// Nocturne: the editor (Full Frame look). The photo fills the window; tool rail, recipe and command pill float above it.
import NocturneKit
import SwiftUI

struct EditorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Color.black
            Canvas()
            if !model.controlsHidden {
                TopLine()
                Sides()
                BottomDock()
                Counter()
            }
        }
    }
}

private struct TopLine: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Button {
                    model.closeEditor()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Library")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glass(Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Text(caption)
                    .shadow(color: .black.opacity(0.7), radius: 6, y: 1)
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.white.opacity(0.8))
            .padding(.leading, 78)
            .padding(.trailing, 18)
            .padding(.top, 8)
            Spacer()
        }
    }

    private var caption: String {
        guard let photo = model.current else { return "" }
        let summary = photo.meta.summary
        return summary.isEmpty ? photo.name : "\(photo.name) · \(summary)"
    }
}

private struct Counter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Text(model.position)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.7), radius: 6, y: 1)
                Spacer()
            }
        }
        .padding(.leading, 20)
        .padding(.bottom, 34)
        .allowsHitTesting(false)
    }
}

private struct Sides: View {
    var body: some View {
        HStack {
            Rail()
            Spacer()
            RecipeCard()
        }
        .padding(.horizontal, 16)
    }
}

private struct Rail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            ForEach(StepKind.allCases, id: \.self) { kind in
                RailButton(kind: kind)
            }
        }
        .padding(6)
        .glass(RoundedRectangle(cornerRadius: 14))
    }
}

private struct RailButton: View {
    @EnvironmentObject var model: AppModel
    let kind: StepKind

    var body: some View {
        let active: Bool = model.recipe.steps.contains { $0.id == model.selectedStep && $0.kind == kind }
        Button {
            model.focusTool(kind)
        } label: {
            Image(systemName: kind.symbol)
                .font(.system(size: 15))
                .frame(width: 32, height: 32)
                .foregroundStyle(active ? Color.white : Color.white.opacity(0.7))
                .background(active ? Color.white.opacity(0.14) : Color.clear, in: ConcentricRectangle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kind.title)
        .accessibilityLabel(kind.title)
    }
}

private struct RecipeCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("RECIPE")
                Spacer()
                Text(count)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.7)
            .foregroundStyle(Color.white.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)
            if model.recipe.steps.isEmpty {
                Text("Describe a look below, or pick a tool on the left.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            ForEach(model.recipe.steps) { step in
                StepRow(step: step)
            }
        }
        .padding(6)
        .frame(width: 262)
        .glass(RoundedRectangle(cornerRadius: 14))
    }

    private var count: String {
        let n = model.recipe.steps.count
        return n == 0 ? "" : "\(n) STEP\(n == 1 ? "" : "S")"
    }
}

private struct StepRow: View {
    @EnvironmentObject var model: AppModel
    let step: Step
    @State private var hover = false

    var body: some View {
        let open: Bool = model.selectedStep == step.id
        VStack(spacing: 4) {
            HStack(spacing: 9) {
                Text(step.name)
                    .lineLimit(1)
                    .foregroundStyle(step.on ? Color.white.opacity(0.95) : Color.white.opacity(0.45))
                Spacer(minLength: 4)
                if hover {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .onTapGesture { model.delete(step.id) }
                } else if step.ai {
                    Text("AI").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.5))
                }
                MiniToggle(on: step.on) { model.toggle(step.id) }
            }
            .font(.system(size: 13))
            .contentShape(Rectangle())
            .onTapGesture { model.selectedStep = open ? nil : step.id }
            if open {
                ForEach(step.kind.params) { spec in
                    ParamRow(step: step, spec: spec)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(open ? Color.white.opacity(0.07) : Color.clear, in: ConcentricRectangle())
        .onHover { hover = $0 }
    }
}

private struct ParamRow: View {
    @EnvironmentObject var model: AppModel
    let step: Step
    let spec: ParamSpec

    var body: some View {
        let value: Double = step.value(spec.key)
        HStack(spacing: 10) {
            Text(spec.label)
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(width: 66, alignment: .leading)
            ThinSlider(
                value: value,
                range: spec.min...spec.max,
                neutral: spec.def,
                onBegin: { model.beginEdit() },
                onChange: { model.setParam(step.id, spec.key, $0) },
                onEnd: { model.endEdit() }
            )
            Text(spec.text(value))
                .foregroundStyle(Color.white.opacity(0.6))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
        .font(.system(size: 11))
    }
}

private struct BottomDock: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            if model.exportDraft != nil {
                ExportCard()
            } else {
                HStack(spacing: 8) {
                    if let notice = model.notice {
                        Chip(text: notice.text, isError: notice.isError)
                    }
                    HoldChip()
                    Button {
                        model.beginExport()
                    } label: {
                        Chip(text: "Export")
                    }
                    .buttonStyle(.plain)
                }
            }
            Pill()
        }
        .padding(.bottom, 22)
        .padding(.horizontal, 300)
    }
}

private struct HoldChip: View {
    @EnvironmentObject var model: AppModel
    @State private var held = false

    var body: some View {
        Chip(text: "Before / After")
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !held {
                            held = true
                            model.showOriginal = true
                            model.refresh()
                        }
                    }
                    .onEnded { _ in
                        held = false
                        model.showOriginal = false
                        model.refresh()
                    }
            )
            .help("Hold to see the original (or hold \\)")
    }
}

private struct Pill: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle")
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
            TextField("Describe the look…", text: $model.prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit { model.describe() }
                .disabled(model.aiBusy)
            if model.aiBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 580, height: 46)
        .glass(Capsule())
        .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
        .onChange(of: model.focusPrompt) { _, _ in focused = true }
    }
}

private struct ExportCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let draft: ExportDraft = model.exportDraft ?? ExportDraft(name: "", suggesting: false, touched: false, working: false, renamable: false)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.suggesting ? "Finding a name…" : (draft.renamable ? "Export to Processed as" : "Export again over"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                TextField("Name", text: nameBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .disabled(!draft.renamable || draft.working)
                    .onSubmit { model.confirmExport() }
            }
            if draft.working { ProgressView().controlSize(.small) }
            Button {
                model.exportDraft = nil
            } label: {
                Text("Cancel")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.7))
            Button {
                model.confirmExport()
            } label: {
                Text("Export")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(white: 0.08))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(draft.working)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 580)
        .glass(RoundedRectangle(cornerRadius: 16))
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { model.exportDraft?.name ?? "" },
            set: { text in
                guard var draft = model.exportDraft, draft.name != text else { return }
                draft.name = text
                draft.touched = true
                model.exportDraft = draft
            }
        )
    }
}
