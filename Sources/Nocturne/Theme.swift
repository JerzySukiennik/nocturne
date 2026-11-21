// Nocturne: colors and the small custom controls (thin slider, mini toggle, glass panel, chip).
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.949, green: 0.847, blue: 0.541)
    static let graphite = Color(red: 0.110, green: 0.110, blue: 0.118)
    static let panel = Color(red: 0.137, green: 0.137, blue: 0.145)
    static let well = Color(red: 0.094, green: 0.094, blue: 0.102)
    static let line = Color.white.opacity(0.08)
    static let text = Color(red: 0.87, green: 0.87, blue: 0.88)
    static let dim = Color(red: 0.557, green: 0.557, blue: 0.576)
    static let faint = Color(red: 0.467, green: 0.467, blue: 0.486)
    static let error = Color(red: 1.0, green: 0.42, blue: 0.38)
}

struct Glass<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background(Color(white: 0.07).opacity(0.62), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.11), lineWidth: 1))
            .containerShape(shape)
    }
}

extension View {
    func glass<S: InsettableShape>(_ shape: S) -> some View {
        modifier(Glass(shape: shape))
    }
}

struct MiniToggle: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Capsule()
            .fill(on ? Theme.accent : Color.white.opacity(0.18))
            .frame(width: 26, height: 16)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(on ? Color(white: 0.1) : Color(white: 0.85))
                    .frame(width: 12, height: 12)
                    .padding(2)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .animation(.snappy(duration: 0.16), value: on)
    }
}

struct ThinSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    @State private var dragging = false

    private func fraction(_ v: Double) -> CGFloat {
        CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        GeometryReader { geo in
            let w: CGFloat = geo.size.width
            let x: CGFloat = fraction(value) * w
            let n: CGFloat = fraction(neutral) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18)).frame(height: 2)
                Capsule().fill(Theme.accent).frame(width: abs(x - n), height: 2).offset(x: min(x, n))
                Circle().fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .offset(x: x - 6)
            }
            .frame(height: 18)
            .contentShape(Rectangle().inset(by: -9))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging {
                            dragging = true
                            onBegin()
                        }
                        let t = Double(min(max(g.location.x / max(w, 1), 0), 1))
                        onChange(range.lowerBound + t * (range.upperBound - range.lowerBound))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnd()
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    onBegin()
                    onChange(neutral)
                    onEnd()
                }
            )
        }
        .frame(height: 18)
    }
}

struct Chip: View {
    let text: String
    var accent: String?
    var isError = false

    var body: some View {
        HStack(spacing: 5) {
            if let accent {
                Text(accent).fontWeight(.semibold).foregroundStyle(Theme.accent)
            }
            Text(text).foregroundStyle(isError ? Theme.error : Color.white.opacity(0.86))
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glass(Capsule())
    }
}
