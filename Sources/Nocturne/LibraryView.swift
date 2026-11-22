// Nocturne: the library (Darkroom look). Sidebar with the two folders, thumbnail grid with captions, status bar.
import NocturneKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            HStack(spacing: 0) {
                Sidebar()
                Rectangle().fill(Theme.line).frame(width: 1)
                VStack(spacing: 0) {
                    GridArea()
                    Rectangle().fill(Theme.line).frame(height: 1)
                    StatusBar()
                }
            }
        }
        .background(Theme.graphite)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            collect(providers)
            return true
        }
    }

    private func collect(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let box = URLBox()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { box.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.importDropped(box.urls)
        }
    }
}

final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []

    func add(_ url: URL) {
        lock.lock()
        list.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }
}

private struct TopBar: View {
    var body: some View {
        ZStack {
            Theme.panel
            Text("Nocturne")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.dim)
        }
        .frame(height: 40)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("FOLDERS")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(Theme.faint)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(Shelf.allCases, id: \.self) { shelf in
                ShelfRow(shelf: shelf)
            }
            ForEach(model.cards) { card in
                CardSection(card: card)
            }
            Spacer()
            Button {
                model.showInFinder(nil)
            } label: {
                Text("Show in Finder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(width: 190)
        .background(Theme.panel)
    }
}

private struct CardSection: View {
    @EnvironmentObject var model: AppModel
    let card: CameraCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CAMERA")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(Theme.faint)
                .padding(.horizontal, 8)
                .padding(.top, 14)
            VStack(alignment: .leading, spacing: 6) {
                Text(card.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Text("\(card.total) photos on the card").font(.system(size: 11)).foregroundStyle(Theme.dim)
                ForEach(card.days.prefix(4)) { day in
                    CardDayRow(card: card, day: day)
                }
                if card.days.count > 4 {
                    Text("and \(card.days.count - 4) older days").font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
            }
            .padding(10)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
        }
    }
}

private struct CardDayRow: View {
    @EnvironmentObject var model: AppModel
    let card: CameraCard
    let day: CardDay

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.text)
                Text(day.fresh == 0 ? "all imported" : "\(day.fresh) new of \(day.files.count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 2)
            if day.fresh > 0 {
                Button {
                    model.importDay(day, from: card)
                } label: {
                    Text("Import")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.batch != nil)
                .accessibilityLabel("Import \(label)")
            }
        }
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day.day) { return "Today" }
        if calendar.isDateInYesterday(day.day) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: day.day)
    }
}

private struct ShelfRow: View {
    @EnvironmentObject var model: AppModel
    let shelf: Shelf

    var body: some View {
        let active: Bool = model.shelf == shelf
        HStack {
            Text(shelf.rawValue).foregroundStyle(active ? Color.white : Theme.text)
            Spacer()
            Text("\(model.counts[shelf] ?? 0)").font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(active ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.switchShelf(shelf) }
    }
}

private struct GridArea: View {
    @EnvironmentObject var model: AppModel
    private let minCell: CGFloat = 190
    private let gap: CGFloat = 12
    private let pad: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let cols: Int = max(1, Int((geo.size.width - pad * 2 + gap) / (minCell + gap)))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Header()
                        if model.photos.isEmpty && model.scanned {
                            EmptyShelf()
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: cols), spacing: 16) {
                                ForEach(model.photos) { photo in
                                    Cell(photo: photo).id(photo.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, pad)
                    .padding(.vertical, 16)
                }
                .onChange(of: model.selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .onAppear { model.columns = cols }
            .onChange(of: cols) { _, value in model.columns = value }
        }
    }
}

private struct Header: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(model.shelf.rawValue)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
        }
    }

    private var subtitle: String {
        let n = model.photos.count
        let picked = model.selected.count
        return "\(n) photo\(n == 1 ? "" : "s") · newest first" + (picked > 1 ? " · \(picked) selected" : "")
    }
}

private struct EmptyShelf: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Text(model.shelf == .toProcess ? "Nothing to process" : "Nothing finished yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(model.shelf == .toProcess
                 ? "Drop photos onto this window, or into Pictures/Nocturne/To Process."
                 : "Exported photos land here, with their originals kept in Processed/Originals.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }
}

private struct Cell: View {
    @EnvironmentObject var model: AppModel
    let photo: Photo

    var body: some View {
        let selected: Bool = model.selected.contains(photo.id)
        let many: Bool = selected && model.selected.count > 1
        let count: Int = model.selected.count
        VStack(alignment: .leading, spacing: 6) {
            Thumb(photo: photo)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2)
                }
                .overlay(alignment: .topLeading) {
                    if photo.edited && photo.shelf == .toProcess {
                        Text("Edited")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                }
            HStack {
                Text(photo.name)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(photo.meta.shutterText ?? "").foregroundStyle(Theme.dim)
            }
            .font(.system(size: 11))
        }
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { model.open(photo) })
        .simultaneousGesture(TapGesture().onEnded { model.click(photo) })
        .contextMenu {
            Button("Open") { model.open(photo) }
            Button("Show in Finder") { model.showInFinder(photo) }
            if photo.shelf == .toProcess {
                Divider()
                Button("Copy Look") {
                    model.focus(photo, keepSelection: false)
                    model.copyLook()
                }
                Button(many ? "Paste Look to \(count) Photos" : "Paste Look") {
                    model.focus(photo, keepSelection: true)
                    model.pasteLook()
                }
                .disabled(!model.hasCopiedLook)
                Menu(many ? "Apply Preset to \(count) Photos" : "Apply Preset") {
                    ForEach(model.presets) { preset in
                        Button(preset.name) {
                            model.focus(photo, keepSelection: true)
                            model.applyToSelection(preset.recipe, label: "Applying \(preset.name)")
                        }
                    }
                }
                .disabled(model.presets.isEmpty)
                Button(many ? "Export \(count) Photos" : "Export") {
                    model.focus(photo, keepSelection: true)
                    model.exportSelection()
                }
            }
            Divider()
            Button(many ? "Move \(count) to Trash" : "Move to Trash") { model.trashSelection(including: photo) }
        }
    }
}

private struct Thumb: View {
    @EnvironmentObject var model: AppModel
    let photo: Photo
    @State private var image: CGImage?

    var body: some View {
        Color.clear
            .aspectRatio(1.5, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Theme.panel
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .task(id: "\(photo.id)|\(photo.modified.timeIntervalSince1970)|\(model.thumbEpoch)") {
                image = await model.thumbs.image(for: photo)
            }
    }
}

private struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if let batch = model.batch {
                ProgressView().controlSize(.mini)
                Text("\(batch.label) \(batch.done) / \(batch.total)").foregroundStyle(Theme.accent)
            } else if let notice = model.notice {
                Text(notice.text).foregroundStyle(notice.isError ? Theme.error : Theme.accent)
            } else {
                Text(summary)
            }
            Spacer()
            Text("Return opens · Cmd-click selects more · right-click for batch")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.dim)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(Theme.panel)
    }

    private var summary: String {
        let edited = model.photos.filter { $0.edited }.count
        if model.shelf == .processed { return "\(model.photos.count) finished" }
        return "\(model.photos.count) waiting · \(edited) edited"
    }
}
