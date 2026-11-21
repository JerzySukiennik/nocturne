// Nocturne: the recipe, an ordered list of named editing steps saved next to every photo.
import Foundation

public struct ParamSpec: Sendable, Identifiable {
    public let key: String
    public let label: String
    public let min: Double
    public let max: Double
    public let def: Double
    public let decimals: Int

    public var id: String { key }

    init(_ key: String, _ label: String, _ min: Double, _ max: Double, _ def: Double = 0, decimals: Int = 0) {
        self.key = key
        self.label = label
        self.min = min
        self.max = max
        self.def = def
        self.decimals = decimals
    }

    public func clamp(_ v: Double) -> Double {
        Swift.min(Swift.max(v, min), max)
    }

    public func text(_ v: Double) -> String {
        if decimals == 0 { return String(Int(v.rounded())) }
        return String(format: "%.\(decimals)f", v)
    }
}

public enum MaskKind: String, Codable, CaseIterable, Sendable {
    case subject, person, background, sky, near, far

    public var title: String {
        switch self {
        case .subject: return "Subject"
        case .person: return "Person"
        case .background: return "Background"
        case .sky: return "Sky"
        case .near: return "Near"
        case .far: return "Far"
        }
    }

    public var needsDepth: Bool {
        self == .sky || self == .near || self == .far
    }
}

public enum StepKind: String, Codable, CaseIterable, Sendable {
    case light, color, grade, splash, vignette, mist, grain, match

    public static let tools: [StepKind] = [.light, .color, .grade, .splash, .vignette, .mist, .grain]

    public var title: String {
        switch self {
        case .light: return "Light"
        case .color: return "Color"
        case .grade: return "Grade"
        case .splash: return "Color Splash"
        case .vignette: return "Vignette"
        case .mist: return "Mist"
        case .grain: return "Grain"
        case .match: return "Match"
        }
    }

    public var symbol: String {
        switch self {
        case .light: return "sun.max"
        case .color: return "drop"
        case .grade: return "circle.lefthalf.filled"
        case .splash: return "drop.halffull"
        case .vignette: return "circle.dashed"
        case .mist: return "cloud.fog"
        case .grain: return "circle.dotted"
        case .match: return "photo.on.rectangle"
        }
    }

    public var params: [ParamSpec] {
        switch self {
        case .light:
            return [
                ParamSpec("exposure", "Exposure", -3, 3, 0, decimals: 2),
                ParamSpec("contrast", "Contrast", -100, 100),
                ParamSpec("highlights", "Highlights", -100, 100),
                ParamSpec("shadows", "Shadows", -100, 100),
                ParamSpec("whites", "Whites", -100, 100),
                ParamSpec("blacks", "Blacks", -100, 100)
            ]
        case .color:
            return [
                ParamSpec("temperature", "Warmth", -100, 100),
                ParamSpec("tint", "Tint", -100, 100),
                ParamSpec("vibrance", "Vibrance", -100, 100),
                ParamSpec("saturation", "Saturation", -100, 100)
            ]
        case .grade:
            return [
                ParamSpec("shadowHue", "Shadow hue", 0, 360, 220),
                ParamSpec("shadowAmount", "Shadows", 0, 100),
                ParamSpec("highlightHue", "Light hue", 0, 360, 40),
                ParamSpec("highlightAmount", "Lights", 0, 100),
                ParamSpec("balance", "Balance", -100, 100)
            ]
        case .splash:
            return [
                ParamSpec("amount", "Amount", 0, 100),
                ParamSpec("hue", "Keep hue", 0, 360, 30),
                ParamSpec("range", "Range", 5, 180, 40)
            ]
        case .vignette:
            return [
                ParamSpec("amount", "Amount", -100, 100),
                ParamSpec("size", "Size", 0, 100, 50)
            ]
        case .mist:
            return [
                ParamSpec("amount", "Amount", 0, 100),
                ParamSpec("spread", "Spread", 0, 100, 50)
            ]
        case .grain:
            return [
                ParamSpec("amount", "Amount", 0, 100),
                ParamSpec("size", "Size", 0, 100, 30)
            ]
        case .match:
            return [
                ParamSpec("amount", "Amount", 0, 100, 100)
            ]
        }
    }

    var drivers: [String] {
        switch self {
        case .light: return ["exposure", "contrast", "highlights", "shadows", "whites", "blacks"]
        case .color: return ["temperature", "tint", "vibrance", "saturation"]
        case .grade: return ["shadowAmount", "highlightAmount"]
        case .splash, .vignette, .mist, .grain, .match: return ["amount"]
        }
    }
}

public struct Step: Codable, Identifiable, Equatable, Sendable {
    public static let matchCount = 28

    public var id: UUID
    public var kind: StepKind
    public var name: String
    public var on: Bool
    public var ai: Bool
    public var params: [String: Double]
    public var mask: MaskKind?
    public var data: [Double]?

    public init(kind: StepKind, name: String? = nil, ai: Bool = false, params: [String: Double] = [:], mask: MaskKind? = nil, data: [Double]? = nil) {
        self.id = UUID()
        self.kind = kind
        self.name = name ?? kind.title
        self.on = true
        self.ai = ai
        self.params = [:]
        self.mask = mask
        self.data = data
        for spec in kind.params {
            if let v = params[spec.key], v.isFinite {
                self.params[spec.key] = spec.clamp(v)
            }
        }
    }

    public func value(_ key: String) -> Double {
        if let v = params[key] { return v }
        return kind.params.first { $0.key == key }?.def ?? 0
    }

    public var isNeutral: Bool {
        if kind == .match && (data?.count ?? 0) != Step.matchCount { return true }
        return kind.drivers.allSatisfy { abs(value($0)) < 0.0001 }
    }

    public func fresh() -> Step {
        var copy = self
        copy.id = UUID()
        return copy
    }
}

public struct Recipe: Codable, Equatable, Sendable {
    public var version: Int
    public var steps: [Step]

    public init(steps: [Step] = []) {
        self.version = 1
        self.steps = steps
    }

    public var hasEffect: Bool {
        steps.contains { $0.on && !$0.isNeutral }
    }

    public var manual: Recipe {
        Recipe(steps: steps.filter { !$0.ai })
    }

    public var maskKinds: Set<MaskKind> {
        Set(steps.filter { $0.on && !$0.isNeutral }.compactMap { $0.mask })
    }

    public func fresh() -> Recipe {
        Recipe(steps: steps.map { $0.fresh() })
    }
}
