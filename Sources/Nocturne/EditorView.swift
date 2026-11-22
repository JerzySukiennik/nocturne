// Nocturne: the editor (Full Frame look). The photo fills the window; tool rail, recipe with masks, presets and the command pill float above it.
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
                if model.loading || model.maskBusy {
                    ProgressView().controlSize(.small)
                }
                if model.maskBusy {
                    Text("Finding masks…").shadow(color: .black.opacity(0.7), radius: 6, y: 1)
                }
                if model.cleanBusy {
                    Text("Cleaning up…").shadow(color: .black.opacity(0.7), radius: 6, y: 1)
                }
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
    @State private var lensOpen = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 4) {
                ForEach(StepKind.tone, id: \.self) { kind in
                    RailButton(kind: kind)
                }
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 20, height: 1).padding(.vertical, 3)
                RailButton(kind: .lamp)
                lensButton
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 20, height: 1).padding(.vertical, 3)
                RailButton(kind: .cleanup)
            }
            .padding(6)
            .glass(RoundedRectangle(cornerRadius: 14))
            if lensOpen {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(StepKind.lens, id: \.self) { kind in
                        LensRow(kind: kind) { lensOpen = false }
                    }
                }
                .padding(6)
                .glass(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var lensButton: some View {
        let active: Bool = lensOpen || model.recipe.steps.contains { $0.id == model.selectedStep && StepKind.lens.contains($0.kind) }
        return Button {
            lensOpen.toggle()
        } label: {
            Image(systemName: "camera.filters")
                .font(.system(size: 15))
                .frame(width: 32, height: 32)
                .foregroundStyle(active ? Color.white : Color.white.opacity(0.7))
                .background(active ? Color.white.opacity(0.14) : Color.clear, in: ConcentricRectangle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Lens Lab")
        .accessibilityLabel("Lens Lab")
    }
}

private struct LensRow: View {
    @EnvironmentObject var model: AppModel
    let kind: StepKind
    let done: () -> Void
    @State private var hover = false

    var body: some View {
        Button {
            model.focusTool(kind)
            done()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: kind.symbol).font(.system(size: 13)).frame(width: 18)
                Text(kind.title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 8)
            .frame(width: 138, height: 28)
            .background(hover ? Color.white.opacity(0.1) : Color.clear, in: ConcentricRectangle())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(kind.title)
    }
}

private struct RailButton: View {
    @EnvironmentObject var model: AppModel
    let kind: StepKind

    var body: some View {
        let active: Bool = kind == .cleanup ? model.cleanupActive : model.recipe.steps.contains { $0.id == model.selectedStep && $0.kind == kind }
        Button {
            model.focusTool(kind)
        } label: {
            Image(systemName: kind.symbol)
                .font(.system(size: 15))
                .frame(width: 32, height: 32)
                .foregroundStyle(active ? (kind == .cleanup ? Color(white: 0.08) : Color.white) : Color.white.opacity(0.7))
                .background(active ? (kind == .cleanup ? Theme.accent : Color.white.opacity(0.14)) : Color.clear, in: ConcentricRectangle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kind == .lamp ? "Lamp (click again to add another)" : kind.title)
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
                Text("Describe a look below, pick a tool on the left, or paste a reference image with Cmd+V.")
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(step.name)
                    .lineLimit(1)
                    .foregroundStyle(step.on ? Color.white.opacity(0.95) : Color.white.opacity(0.45))
                if let mask = step.mask {
                    Text(mask.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.16), in: Capsule())
                        .fixedSize()
                }
                Spacer(minLength: 2)
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
                if let hint = step.kind.hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(step.kind.params) { spec in
                    ParamRow(step: step, spec: spec)
                }
                if step.kind != .cleanup {
                    MaskRow(step: step)
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

private struct MaskRow: View {
    @EnvironmentObject var model: AppModel
    let step: Step

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                MaskChip(step: step, kind: nil)
                MaskChip(step: step, kind: .subject)
                MaskChip(step: step, kind: .person)
                MaskChip(step: step, kind: .background)
            }
            HStack(spacing: 4) {
                MaskChip(step: step, kind: .sky)
                MaskChip(step: step, kind: .near)
                MaskChip(step: step, kind: .far)
            }
        }
        .padding(.top, 5)
        .onHover { inside in
            if !inside { model.previewMask(nil) }
        }
    }
}

private struct MaskChip: View {
    @EnvironmentObject var model: AppModel
    let step: Step
    let kind: MaskKind?

    var body: some View {
        let active: Bool = step.mask == kind
        Text(kind?.title ?? "All")
            .font(.system(size: 10.5, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? Color(white: 0.08) : Color.white.opacity(0.78))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(active ? Theme.accent : Color.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { model.setMask(step.id, kind) }
            .onHover { inside in
                if inside { model.previewMask(kind) }
            }
            .help(kind == nil ? "Apply to the whole photo" : "Apply only to: \(kind?.title ?? "")")
    }
}

private struct BottomDock: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            if model.exportDraft != nil {
                ExportCard()
            } else if model.cleanupActive {
                CleanupCard()
            } else if model.presetsOpen {
                PresetsCard()
            } else {
                HStack(spacing: 8) {
                    if let notice = model.notice {
                        Chip(text: notice.text, isError: notice.isError)
                    }
                    HoldChip()
                    Button {
                        model.presetsOpen = true
                    } label: {
                        Chip(text: "Presets")
                    }
                    .buttonStyle(.plain)
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
    }
}

private struct CleanupCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bandage").font(.system(size: 15)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean Up").font(.system(size: 13, weight: .semibold))
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            Spacer(minLength: 8)
            if model.cleanBusy || !model.cleanReady {
                ProgressView().controlSize(.small)
            }
            Text("Brush").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55))
            ThinSlider(value: model.brush, range: 0.4...6, neutral: 0.4, onBegin: {}, onChange: { model.brush = $0 }, onEnd: {})
                .frame(width: 110)
            Button {
                model.toggleCleanup()
            } label: {
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.08))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 580)
        .glass(RoundedRectangle(cornerRadius: 16))
    }

    private var status: String {
        if model.cleanBusy { return "Filling in…" }
        if !model.cleanReady { return "Getting ready, the first time takes a few seconds…" }
        return "Paint over what should disappear. Cmd+Z brings it back."
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

private struct PresetsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("PRESETS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.7)
                    .foregroundStyle(Color.white.opacity(0.5))
                Spacer()
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.presetsOpen = false
                        model.previewPreset(nil)
                    }
            }
            .padding(.bottom, 4)
            if model.presets.isEmpty {
                Text("No presets yet. Build a look, name it below and save it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.presets) { preset in
                            PresetRow(preset: preset)
                        }
                    }
                }
                .frame(height: min(CGFloat(model.presets.count) * 30, 180))
            }
            HStack(spacing: 10) {
                TextField("Save this look as…", text: $model.presetName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { model.savePreset() }
                Button {
                    model.savePreset()
                } label: {
                    Text("Save")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(white: 0.08))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!model.recipe.hasEffect)
                .opacity(model.recipe.hasEffect ? 1 : 0.4)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 580)
        .glass(RoundedRectangle(cornerRadius: 16))
        .onHover { inside in
            if !inside { model.previewPreset(nil) }
        }
    }
}

private struct PresetRow: View {
    @EnvironmentObject var model: AppModel
    let preset: Preset
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Text(preset.name).foregroundStyle(Color.white.opacity(0.95))
            Spacer()
            Text("\(preset.recipe.steps.count) step\(preset.recipe.steps.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))
            if hover {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture { model.deletePreset(preset) }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(hover ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { model.applyPreset(preset) }
        .onHover { inside in
            hover = inside
            if inside { model.previewPreset(preset) }
        }
    }
}

private struct ExportCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let draft: ExportDraft = model.exportDraft ?? ExportDraft(name: "", suggesting: false, touched: false, working: false, renamable: false)
        let framed: Bool = model.frameStyle != .plain
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(FrameStyle.allCases, id: \.self) { style in
                    StyleChip(title: style.title, active: model.frameStyle == style) { model.setFrameStyle(style) }
                }
                Spacer()
                if framed {
                    StyleChip(title: "White", active: !model.frameDark) { model.setFrameDark(false) }
                    StyleChip(title: "Black", active: model.frameDark) { model.setFrameDark(true) }
                }
            }
            if framed {
                HStack(spacing: 10) {
                    LabeledField(label: "Shot on", prompt: "Device", text: deviceBinding)
                    LabeledField(label: "Your text", prompt: "Optional", text: noteBinding)
                }
            }
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
                    model.cancelExport()
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
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    private var deviceBinding: Binding<String> {
        Binding(get: { model.exportDraft?.device ?? "" }, set: { model.setFrameDevice($0) })
    }

    private var noteBinding: Binding<String> {
        Binding(get: { model.frameNote }, set: { model.setFrameNote($0) })
    }
}

private struct StyleChip: View {
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color(white: 0.08) : Color.white.opacity(0.8))
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(active ? Theme.accent : Color.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct LabeledField: View {
    let label: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.55))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: ConcentricRectangle())
    }
}
