// nocturnetool: offline checks for the Nocturne engine. Usage: nocturnetool render|describe|name|bench ...
import CoreImage
import Foundation
import NocturneKit

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let start = Date()
    let result = try body()
    print(label, String(format: "%.3fs", Date().timeIntervalSince(start)))
    return result
}

func readRecipe(_ path: String) -> Recipe {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    if let recipe = try? JSONDecoder().decode(Recipe.self, from: data) { return recipe }
    guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { fail("bad recipe json") }
    var steps: [Step] = []
    for item in list {
        guard let kind = (item["kind"] as? String).flatMap(StepKind.init(rawValue:)) else { continue }
        var params: [String: Double] = [:]
        for (k, v) in (item["params"] as? [String: Any]) ?? [:] {
            if let n = v as? NSNumber { params[k] = n.doubleValue }
        }
        steps.append(Step(kind: kind, name: item["name"] as? String, params: params))
    }
    return Recipe(steps: steps)
}

guard let command = args.first else {
    fail("usage: nocturnetool render <in> <out.jpg> [recipe.json] [maxEdge] | describe <in> <prompt> [out.jpg] | name <in> | bench <in>")
}
let engine = Engine.shared

switch command {
case "render":
    guard args.count >= 3 else { fail("render <in> <out.jpg> [recipe.json] [maxEdge]") }
    let source = try timed("load") { try engine.load(URL(fileURLWithPath: args[1])) }
    let recipe = args.count > 3 ? readRecipe(args[3]) : Recipe()
    var image = engine.render(source.image, recipe: recipe)
    if args.count > 4, let edge = Double(args[4]) { image = engine.scaled(image, maxEdge: edge) }
    try timed("export") { try engine.export(image, to: URL(fileURLWithPath: args[2]), properties: source.properties) }
    print("size", Int(image.extent.width), "x", Int(image.extent.height), "raw", source.isRAW)

case "describe":
    guard args.count >= 3 else { fail("describe <in> <prompt> [out.jpg]") }
    let source = try engine.load(URL(fileURLWithPath: args[1]))
    guard let preview = engine.jpegData(source.image, maxEdge: 768, quality: 0.8) else { fail("no preview") }
    let start = Date()
    let provider = AIProvider(rawValue: ProcessInfo.processInfo.environment["NOCTURNE_AI"] ?? "") ?? .opus
    let answer = try await Assistant().describeLook(prompt: args[2], preview: preview, previous: [], provider: provider)
    print(String(format: "answer %.1fs", Date().timeIntervalSince(start)), "via", answer.via, "|", answer.note)
    if let u = answer.usage { print(String(format: "usage: %d in, %d out, $%.5f", u.inputTokens, u.outputTokens, u.dollars), u.model) }
    for step in answer.steps { print(" ", step.kind.rawValue, step.mask?.rawValue ?? "all", step.name, step.params) }
    if args.count > 3 {
        let recipe = Recipe(steps: answer.steps)
        let masks = MaskSet()
        if !recipe.maskKinds.isEmpty { Masker(engine: engine).compute(recipe.maskKinds, source: source.image, into: masks) }
        let image = engine.scaled(engine.render(source.image, recipe: recipe, masks: masks), maxEdge: 1400)
        try engine.export(image, to: URL(fileURLWithPath: args[3]), properties: [:])
    }

case "name":
    guard args.count >= 2 else { fail("name <in>") }
    let source = try engine.load(URL(fileURLWithPath: args[1]))
    guard let preview = engine.jpegData(source.image, maxEdge: 512, quality: 0.75) else { fail("no preview") }
    let provider = AIProvider(rawValue: ProcessInfo.processInfo.environment["NOCTURNE_AI"] ?? "") ?? .opus
    print(try await Assistant().suggestName(preview: preview, provider: provider))

case "bench":
    guard args.count >= 2 else { fail("bench <in>") }
    let source = try timed("load") { try engine.load(URL(fileURLWithPath: args[1])) }
    let kinds: [(String, [Step])] = [
        ("none", []),
        ("light", [Step(kind: .light, params: ["exposure": 0.3, "shadows": 40, "highlights": -40, "contrast": 15])]),
        ("light+color+grade", [
            Step(kind: .light, params: ["exposure": 0.3, "shadows": 40]),
            Step(kind: .color, params: ["temperature": 20, "vibrance": 20]),
            Step(kind: .grade, params: ["shadowAmount": 30, "highlightAmount": 20])
        ]),
        ("all six", [
            Step(kind: .light, params: ["exposure": 0.3, "shadows": 40]),
            Step(kind: .color, params: ["temperature": 20, "vibrance": 20]),
            Step(kind: .grade, params: ["shadowAmount": 30, "highlightAmount": 20]),
            Step(kind: .vignette, params: ["amount": -30]),
            Step(kind: .mist, params: ["amount": 30]),
            Step(kind: .grain, params: ["amount": 30])
        ])
    ]
    for (label, steps) in kinds {
        for round in 1...3 {
            var varied = steps
            if !varied.isEmpty { varied[0].params["exposure"] = 0.1 * Double(round) }
            let image = engine.scaled(engine.render(source.image, recipe: Recipe(steps: varied)), maxEdge: 2880)
            timed("\(label) #\(round)") { _ = engine.context.createCGImage(image, from: image.extent) }
        }
    }

case "masks":
    guard args.count >= 3 else { fail("masks <in> <outdir>") }
    let source = try engine.load(URL(fileURLWithPath: args[1]))
    let masker = Masker(engine: engine)
    let set = MaskSet()
    print("depth model available:", masker.depthAvailable)
    for group: Set<MaskKind> in [[.subject, .background], [.person], [.sky, .near, .far]] {
        timed("masks \(group.map { $0.rawValue }.sorted())") { masker.compute(group, source: source.image, into: set) }
    }
    for kind in MaskKind.allCases {
        guard let mask = set.image(kind) else { print("missing", kind.rawValue); continue }
        let out = URL(fileURLWithPath: args[2]).appendingPathComponent("mask-\(kind.rawValue).jpg")
        try engine.export(engine.scaled(mask, maxEdge: 700), to: out, properties: [:])
    }
    let look = Recipe(steps: [
        Step(kind: .light, params: ["exposure": -1.0], mask: .sky),
        Step(kind: .light, params: ["exposure": 0.6, "shadows": 30], mask: .near)
    ])
    let graded = engine.scaled(engine.render(source.image, recipe: look, masks: set), maxEdge: 1200)
    try engine.export(graded, to: URL(fileURLWithPath: args[2]).appendingPathComponent("masked-look.jpg"), properties: [:])

case "match":
    guard args.count >= 4 else { fail("match <in> <reference> <out.jpg>") }
    let source = try engine.load(URL(fileURLWithPath: args[1]))
    let reference = try engine.load(URL(fileURLWithPath: args[2]))
    guard let step = timed("stats", { engine.matchStep(reference: reference.image, current: source.image) }) else { fail("no stats") }
    print("data", step.data?.map { String(format: "%.3f", $0) }.joined(separator: " ") ?? "")
    let image = engine.scaled(engine.render(source.image, recipe: Recipe(steps: [step])), maxEdge: 1200)
    try engine.export(image, to: URL(fileURLWithPath: args[3]), properties: [:])

case "lens":
    guard args.count >= 3 else { fail("lens <in> <outdir>") }
    let source = try engine.load(URL(fileURLWithPath: args[1]))
    let masker = Masker(engine: engine)
    let set = MaskSet()
    timed("depth") { masker.compute([], depth: true, source: source.image, into: set) }
    let looks: [(String, [Step])] = [
        ("lamp", [Step(kind: .lamp, params: ["x": 25, "y": 55, "height": 35, "intensity": 70, "warmth": 60, "ambient": -50])]),
        ("lampdefault", [Step(kind: .lamp, params: ["x": 30, "y": 80])]),
        ("lampstrong", [Step(kind: .lamp, params: ["x": 30, "y": 80, "intensity": 100])]),
        ("lampbehind", [Step(kind: .lamp, params: ["x": 52, "y": 70, "height": 38, "intensity": 100, "warmth": 60, "ambient": -60, "radius": 45])]),
        ("glow", [Step(kind: .halation, params: ["amount": 70]), Step(kind: .bloom, params: ["amount": 50])]),
        ("streaks", [Step(kind: .streaks, params: ["amount": 80, "length": 70]), Step(kind: .fringe, params: ["amount": 100])])
    ]
    for (label, steps) in looks {
        let recipe = Recipe(steps: steps)
        for round in 1...2 {
            var varied = recipe
            varied.steps[0].params["x"] = 25 + Double(round)
            let preview = engine.scaled(engine.render(source.image, recipe: varied, masks: set), maxEdge: 2880)
            timed("\(label) preview #\(round)") { _ = engine.context.createCGImage(preview, from: preview.extent) }
        }
        let image = engine.scaled(engine.render(source.image, recipe: recipe, masks: set), maxEdge: 900)
        try engine.export(image, to: URL(fileURLWithPath: args[2]).appendingPathComponent("lens-\(label).jpg"), properties: [:])
    }

case "clean":
    guard args.count >= 7 else { fail("clean <in> <out.jpg> x0 y0 x1 y1 (0..1 from the top-left)") }
    let source = try engine.load(URL(fileURLWithPath: args[1]))
    let e = source.image.extent
    let nums = args[3...6].compactMap { Double($0) }
    let points = [CGPoint(x: nums[0] * e.width, y: (1 - nums[1]) * e.height), CGPoint(x: nums[2] * e.width, y: (1 - nums[3]) * e.height)]
    let radius = max(e.width, e.height) * (args.count > 7 ? (Double(args[7]) ?? 0.02) : 0.02)
    guard let mask = engine.strokeMask(points: points, radius: radius, extent: e) else { fail("no mask") }
    let painter = Inpainter(engine: engine)
    print("model available:", painter.available)
    let region = Engine.strokeRegion(points: points, radius: radius, extent: e)
    var patch: CIImage?
    for round in 1...2 { patch = timed("inpaint #\(round)") { painter.patch(base: source.image, mask: mask, region: region) } }
    guard let patch else { fail("inpainting failed") }
    let view = region.insetBy(dx: -region.width * 1.5, dy: -region.height * 1.0).intersection(e)
    let after = patch.composited(over: source.image).cropped(to: view)
    let before = source.image.cropped(to: view).transformed(by: CGAffineTransform(translationX: -view.width - 8, y: 0))
    let both = before.composited(over: after)
    let moved = both.transformed(by: CGAffineTransform(translationX: -both.extent.minX, y: -both.extent.minY))
    try engine.export(engine.scaled(moved, maxEdge: 1500), to: URL(fileURLWithPath: args[2]), properties: [:])

case "frame":
    guard args.count >= 3 else { fail("frame <in> <outdir>") }
    let url = URL(fileURLWithPath: args[1])
    let source = try engine.load(url)
    let meta = PhotoMeta.read(url)
    print("device:", meta.deviceName, "| settings:", meta.settingsLine)
    let look = Recipe(steps: [
        Step(kind: .light, params: ["exposure": -0.2, "contrast": 20, "shadows": 20]),
        Step(kind: .color, params: ["temperature": 25, "vibrance": 20]),
        Step(kind: .mist, params: ["amount": 25])
    ])
    let after = engine.render(source.image, recipe: look)
    let device = meta.deviceName.isEmpty ? "iPhone XR" : meta.deviceName
    let sets: [(String, FrameOptions)] = [
        ("frame-white", FrameOptions(style: .frame, dark: false, device: device, settings: meta.settingsLine, note: "")),
        ("frame-black", FrameOptions(style: .frame, dark: true, device: device, settings: meta.settingsLine, note: "Gzowo, November 2026")),
        ("compare", FrameOptions(style: .compare, dark: false, device: device, settings: meta.settingsLine, note: "Gzowo, November 2026"))
    ]
    for (label, options) in sets {
        guard let cg = timed(label, { engine.framed(after: after, before: source.image, options: options, maxEdge: 1500) }) else { fail("no frame") }
        try engine.writeJPEG(cg, to: URL(fileURLWithPath: args[2]).appendingPathComponent("\(label).jpg"), properties: source.properties)
        print(" ", cg.width, "x", cg.height)
    }

case "stack":
    guard args.count >= 5, let mode = StackMode(rawValue: args[1]) else { fail("stack average|lighten|longExposure <out.tif> <frames...>") }
    let urls = args[3...].map { URL(fileURLWithPath: $0) }
    let result = try timed("stack \(mode.rawValue) of \(urls.count)") { try engine.stack(Array(urls), mode: mode) { _ in } }
    try engine.writeTIFF(result.image, to: URL(fileURLWithPath: args[2]), properties: result.properties)
    print("size", result.image.width, "x", result.image.height, "used", result.used)

case "series":
    guard args.count >= 2 else { fail("series <folder>") }
    let lib = Library(root: URL(fileURLWithPath: args[1]))
    for s in Library.findSeries(in: lib.scan(.toProcess)) {
        print("series of", s.count, s.photos.first?.name ?? "", "to", s.photos.last?.name ?? "")
    }

default:
    fail("unknown command \(command)")
}
