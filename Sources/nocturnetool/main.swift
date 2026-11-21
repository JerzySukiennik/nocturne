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
    let answer = try await Gemini().describeLook(prompt: args[2], preview: preview, previous: [])
    print(String(format: "answer %.1fs", Date().timeIntervalSince(start)), answer.note)
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
    print(try await Gemini().suggestName(preview: preview))

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

default:
    fail("unknown command \(command)")
}
