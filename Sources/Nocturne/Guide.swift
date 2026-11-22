// Nocturne: the optional field guide for the Nikon D80, from camera settings to the finished stack, plus the night tint.
import NocturneKit
import SwiftUI

struct GuideStep: Identifiable {
    let title: String
    let body: String

    var id: String { title }
}

struct GuideTopic: Identifiable {
    let title: String
    let symbol: String
    let summary: String
    let stack: String
    let steps: [GuideStep]

    var id: String { title }
}

enum FieldGuide {
    static let topics: [GuideTopic] = [
        GuideTopic(
            title: "Stars", symbol: "sparkles",
            summary: "A sharp, clean night sky from 20 to 40 short exposures.",
            stack: "Average",
            steps: [
                GuideStep(title: "Gear", body: "Tripod, a charged battery, and either the USB cable to this Mac or the MC-DC1 cable release. Pick a dark place and a night without the Moon."),
                GuideStep(title: "Camera", body: "Mode dial to M. Zoom out to 18 mm. Aperture f/3.5 (turn the front dial). Shutter 15 s: at 18 mm the stars stay points up to about 18 s. ISO 1600. Quality NEF (RAW): hold QUAL and turn the rear dial."),
                GuideStep(title: "Turn off", body: "Shooting menu > Long exp. NR > Off. It doubles the wait after every frame, and the stack removes the noise anyway. Flash down. Cover the viewfinder eyepiece so stray light does not leak in."),
                GuideStep(title: "Focus", body: "The D80 has no live view, so focus before it gets fully dark: autofocus on something very far away (the horizon, a distant light, the Moon), then move the lens switch to M and do not touch the focus ring. In the dark, set the distance window just short of the infinity mark, take a test shot and zoom in on the screen: stars must be small dots."),
                GuideStep(title: "Shoot the series", body: "From this Mac: camera USB set to PTP, then in the library set Frames 30, Every 17 s and press Start series. Without the Mac: release mode to continuous, press the cable release and slide its lock; stop after 30 frames. Do not touch the tripod between frames."),
                GuideStep(title: "In Nocturne", body: "The frames arrive in To Process and are recognised as one series. Press Average in the bottom bar. The result appears as a new photo you can edit like any other.")
            ]
        ),
        GuideTopic(
            title: "Moon", symbol: "moon",
            summary: "The sharpest Moon your lens can give, from a burst of fast frames.",
            stack: "Average",
            steps: [
                GuideStep(title: "Gear", body: "Tripod. The Moon is bright, so this is daylight-style shooting: no high ISO needed."),
                GuideStep(title: "Camera", body: "Mode dial to M. Zoom in all the way to 70 mm. Aperture f/8. Shutter 1/200 s. ISO 200. Quality NEF (RAW). If the Moon looks white without detail on the screen, use a faster shutter such as 1/400 s."),
                GuideStep(title: "Focus", body: "Autofocus works on the Moon: put it under the centre focus point and half-press. Then switch the lens to M so the focus does not hunt between frames."),
                GuideStep(title: "Shoot the series", body: "Take 20 to 40 frames. From this Mac: Frames 30, Every 2 s. Without the Mac: continuous release mode and hold the cable release. The air shimmers, so some frames are sharper than others; the stack evens that out."),
                GuideStep(title: "In Nocturne", body: "Press Average: the frames are aligned on the Moon first, because it drifts across the frame. Then crop in and add contrast with Light.")
            ]
        ),
        GuideTopic(
            title: "Star trails", symbol: "circle.dotted",
            summary: "Circles of light around the pole from an hour of frames.",
            stack: "Lighten",
            steps: [
                GuideStep(title: "Gear", body: "Tripod that will not move for an hour, a fully charged battery and an empty card. Point north and include something on the ground for scale."),
                GuideStep(title: "Camera", body: "Mode dial to M. 18 mm, f/4, shutter 30 s, ISO 400. Quality NEF (RAW). Long exp. NR must be Off, otherwise every second 30 s is lost and the trails get gaps."),
                GuideStep(title: "Focus", body: "Same as for stars: focus on something far away while you still can, then switch the lens to M."),
                GuideStep(title: "Shoot the series", body: "You need 60 to 120 frames with as little pause as possible. From this Mac: Frames 100, Every 31 s. Without the Mac: continuous release mode with the cable release locked."),
                GuideStep(title: "In Nocturne", body: "Press Lighten: every frame adds its bright points, so the stars draw lines while the ground stays as it is.")
            ]
        ),
        GuideTopic(
            title: "Silky water", symbol: "water.waves",
            summary: "Smooth water and clouds without a dark filter.",
            stack: "Long exposure",
            steps: [
                GuideStep(title: "Gear", body: "Tripod. Works best at dusk, at dawn or in shade, when shutter speeds are already slow."),
                GuideStep(title: "Camera", body: "Mode dial to M. ISO 100. Aperture f/16 to f/22. Pick the slowest shutter that still exposes correctly, for example 1/4 s. Quality NEF (RAW)."),
                GuideStep(title: "Focus", body: "Autofocus on the rocks or the shore, then switch the lens to M."),
                GuideStep(title: "Shoot the series", body: "Take 20 to 40 frames. From this Mac: Frames 30, Every 2 s. Twenty frames at 1/4 s behave like one 5 second exposure."),
                GuideStep(title: "In Nocturne", body: "Press Long exposure: the frames are averaged without aligning, so everything that moves turns smooth and everything still stays sharp.")
            ]
        )
    ]
}

struct GuideView: View {
    @EnvironmentObject var model: AppModel
    @State private var current = FieldGuide.topics[0].id

    var body: some View {
        let topic: GuideTopic = FieldGuide.topics.first { $0.id == current } ?? FieldGuide.topics[0]
        ZStack {
            Color.black.opacity(0.55)
                .onTapGesture { model.guideOpen = false }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FIELD GUIDE · NIKON D80")
                        .font(.system(size: 10.5, weight: .semibold))
                        .kerning(0.7)
                        .foregroundStyle(Theme.faint)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    ForEach(FieldGuide.topics) { item in
                        Button {
                            current = item.id
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: item.symbol).frame(width: 18)
                                Text(item.title)
                                Spacer()
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(item.id == current ? Color.white : Theme.text)
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .background(item.id == current ? Color.white.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Button {
                        model.guideOpen = false
                    } label: {
                        Text("Close").font(.system(size: 12)).foregroundStyle(Theme.dim).padding(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .frame(width: 190)
                .background(Theme.panel)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(topic.title).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                            Text(topic.summary).font(.system(size: 13)).foregroundStyle(Theme.dim)
                        }
                        ForEach(Array(topic.steps.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color(white: 0.08))
                                    .frame(width: 22, height: 22)
                                    .background(Theme.accent, in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    Text(step.body)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.text)
                                        .lineSpacing(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        Text("Stack mode for this subject: \(topic.stack)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.graphite)
            }
            .frame(width: 780, height: 540)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
        }
    }
}

final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct NightTint: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(red: 1, green: 0.07, blue: 0.03, alpha: 1).cgColor
        view.layer?.compositingFilter = "multiplyBlendMode"
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
