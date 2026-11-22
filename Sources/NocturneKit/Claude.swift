// Nocturne: Claude client (Messages API over HTTP, structured JSON output) and the assistant that picks a provider and falls back to Gemini.
import Foundation

public enum AIProvider: String, CaseIterable, Sendable {
    case opus = "claude-opus-5-5"
    case haiku = "claude-haiku-5-5"
    case gemini = "gemini"

    public var title: String {
        switch self {
        case .opus: return "Claude Opus 5.5"
        case .haiku: return "Claude Haiku 5.5"
        case .gemini: return "Gemini (free)"
        }
    }

    var dollarsPerMillion: (input: Double, output: Double) {
        switch self {
        case .opus: return (4.0, 20.0)
        case .haiku: return (0.10, 0.50)
        case .gemini: return (0, 0)
        }
    }
}

public struct AIUsage: Sendable {
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let dollars: Double
}

public final class Claude: @unchecked Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        session = URLSession(configuration: config)
    }

    public static func loadKeys() -> [String] {
        let env = ProcessInfo.processInfo.environment
        var raw = env["ANTHROPIC_API_KEYS"] ?? env["ANTHROPIC_API_KEY"] ?? ""
        if raw.isEmpty, let text = try? String(contentsOf: Gemini.envFile, encoding: .utf8) {
            var found: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let name = line[..<eq].trimmingCharacters(in: .whitespaces)
                found[name] = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
            raw = found["ANTHROPIC_API_KEYS"] ?? found["ANTHROPIC_API_KEY"] ?? ""
        }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static let lookSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "steps": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": ["light", "color", "grade", "splash", "vignette", "mist", "grain", "lamp", "bokeh", "halation", "bloom", "streaks", "fringe"]],
                        "name": ["type": "string"],
                        "mask": ["type": "string", "enum": ["all", "sky", "subject", "person", "background", "near", "far"]],
                        "params": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": ["key": ["type": "string"], "value": ["type": "number"]],
                                "required": ["key", "value"],
                                "additionalProperties": false
                            ] as [String: Any]
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["kind", "name", "mask", "params"],
                    "additionalProperties": false
                ] as [String: Any]
            ] as [String: Any],
            "note": ["type": "string"]
        ] as [String: Any],
        "required": ["steps", "note"],
        "additionalProperties": false
    ]

    static let nameSchema: [String: Any] = [
        "type": "object",
        "properties": ["name": ["type": "string"]],
        "required": ["name"],
        "additionalProperties": false
    ]

    static let lookExtra = """

    Output shape for this request: params is a list of {"key": ..., "value": ...} pairs using the param names above, and mask is "all" when the step affects the whole photo.
    """

    public func describeLook(prompt: String, preview: Data, previous: [Step], provider: AIProvider) async throws -> LookAnswer {
        var text = prompt
        let old = previous.filter { $0.kind != .match && $0.kind != .cleanup }.map { step -> [String: Any] in
            ["kind": step.kind.rawValue, "name": step.name, "mask": step.mask?.rawValue ?? "all", "params": step.params]
        }
        if !old.isEmpty, let data = try? JSONSerialization.data(withJSONObject: old), let json = String(data: data, encoding: .utf8) {
            text += "\n\nYour earlier steps: " + json
        }
        let (answer, usage) = try await ask(provider: provider, system: Gemini.lookSystem + Claude.lookExtra, text: text, image: preview, schema: Claude.lookSchema)
        guard let list = answer["steps"] as? [[String: Any]] else { throw AIError.badAnswer }
        var steps: [Step] = []
        for item in list {
            guard let kindText = item["kind"] as? String, let kind = StepKind(rawValue: kindText), kind != .match, kind != .cleanup else { continue }
            let mask = (item["mask"] as? String).flatMap { MaskKind(rawValue: $0.lowercased()) }
            if steps.contains(where: { $0.kind == kind && $0.mask == mask }) { continue }
            var params: [String: Double] = [:]
            for pair in (item["params"] as? [[String: Any]]) ?? [] {
                if let key = pair["key"] as? String, let value = pair["value"] as? NSNumber { params[key] = value.doubleValue }
            }
            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let step = Step(kind: kind, name: (name?.isEmpty ?? true) ? nil : name, ai: true, params: params, mask: mask)
            if !step.isNeutral { steps.append(step) }
        }
        guard !steps.isEmpty else { throw AIError.badAnswer }
        return LookAnswer(steps: steps, note: (answer["note"] as? String) ?? "", via: provider.title, usage: usage)
    }

    public func suggestName(preview: Data, provider: AIProvider) async throws -> String {
        let (answer, _) = try await ask(provider: provider, system: Gemini.nameSystem, text: "Nazwij to zdjęcie.", image: preview, schema: Claude.nameSchema)
        let name = Library.cleanName((answer["name"] as? String) ?? "")
        guard !name.isEmpty else { throw AIError.badAnswer }
        return name
    }

    private func ask(provider: AIProvider, system: String, text: String, image: Data, schema: [String: Any]) async throws -> ([String: Any], AIUsage) {
        let keys = Claude.loadKeys()
        guard !keys.isEmpty else { throw AIError.noKey }
        var body: [String: Any] = [
            "model": provider.rawValue,
            "max_tokens": 16000,
            "system": system,
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]],
                    ["type": "text", "text": text]
                ]
            ]]
        ]
        let useFallbacks = provider == .opus
        if useFallbacks { body["fallbacks"] = "default" }
        let payload = try JSONSerialization.data(withJSONObject: body)
        var last = "Claude did not answer."
        for key in keys {
            var busy = 0
            while true {
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.httpBody = payload
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
                if useFallbacks { request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if status == 200 {
                    if (root["stop_reason"] as? String) == "refusal" { throw AIError.offline("Claude declined this request.") }
                    let blocks = (root["content"] as? [[String: Any]]) ?? []
                    let joined = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
                    guard let parsed = (try? JSONSerialization.jsonObject(with: Data(joined.utf8))) as? [String: Any] else { throw AIError.badAnswer }
                    let usage = (root["usage"] as? [String: Any]) ?? [:]
                    let input = (usage["input_tokens"] as? Int) ?? 0
                    let output = (usage["output_tokens"] as? Int) ?? 0
                    let price = provider.dollarsPerMillion
                    let cost = Double(input) / 1_000_000 * price.input + Double(output) / 1_000_000 * price.output
                    return (parsed, AIUsage(model: (root["model"] as? String) ?? provider.rawValue, inputTokens: input, outputTokens: output, dollars: cost))
                }
                let message = ((root["error"] as? [String: Any])?["message"] as? String) ?? "status \(status)"
                last = "Claude: \(message)"
                if (status == 429 || status >= 500), busy < 2 {
                    busy += 1
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                break
            }
        }
        throw AIError.offline(last)
    }
}

public final class Assistant: @unchecked Sendable {
    private let claude = Claude()
    private let gemini = Gemini()

    public init() {}

    public func describeLook(prompt: String, preview: Data, previous: [Step], provider: AIProvider) async throws -> LookAnswer {
        if provider != .gemini {
            do {
                return try await claude.describeLook(prompt: prompt, preview: preview, previous: previous, provider: provider)
            } catch {
                var answer = try await gemini.describeLook(prompt: prompt, preview: preview, previous: previous)
                answer.via = "Gemini, because Claude failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                return answer
            }
        }
        return try await gemini.describeLook(prompt: prompt, preview: preview, previous: previous)
    }

    public func suggestName(preview: Data, provider: AIProvider) async throws -> String {
        if provider != .gemini, let name = try? await claude.suggestName(preview: preview, provider: provider) {
            return name
        }
        return try await gemini.suggestName(preview: preview)
    }
}
