// Nocturne: Gemini free tier client. Turns a described look into recipe steps and suggests file names.
import Foundation

public enum AIError: LocalizedError {
    case noKey
    case offline(String)
    case badAnswer

    public var errorDescription: String? {
        switch self {
        case .noKey: return "No Gemini key found."
        case .offline(let text): return text
        case .badAnswer: return "The model answered with something unreadable."
        }
    }
}

public struct LookAnswer: Sendable {
    public let steps: [Step]
    public let note: String
}

public final class Gemini: @unchecked Sendable {
    public static let envFile: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Nocturne/.env")

    private let models = ["gemini-flash-lite-latest", "gemini-flash-latest"]
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 40
        session = URLSession(configuration: config)
    }

    public static func loadKeys() -> [String] {
        let env = ProcessInfo.processInfo.environment
        var raw = env["GEMINI_API_KEYS"] ?? env["GEMINI_API_KEY"] ?? ""
        if raw.isEmpty, let text = try? String(contentsOf: envFile, encoding: .utf8) {
            var found: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let name = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                found[name] = value
            }
            raw = found["GEMINI_API_KEYS"] ?? found["GEMINI_API_KEY"] ?? ""
        }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static let lookSystem = """
    You are the grading brain of Nocturne, a photo editor. The user describes a look in any language. You see the photo as it looks now, before your steps. Answer with JSON only: {"steps":[{"kind":"...","name":"...","params":{...}}],"note":"..."}.
    Allowed kinds and params (numbers):
    light: exposure [-3,3] in EV, contrast, highlights, shadows, whites, blacks [-100,100]
    color: temperature [-100,100] (positive is warmer), tint [-100,100] (positive is magenta), vibrance, saturation [-100,100]
    grade: shadowHue [0,360], shadowAmount [0,100], highlightHue [0,360], highlightAmount [0,100], balance [-100,100]
    vignette: amount [-100,100] (negative darkens the edges), size [0,100]
    mist: amount [0,100], spread [0,100] (soft glowing diffusion, like a Pro-Mist filter)
    grain: amount [0,100], size [0,100]
    Rules: 1 to 4 steps, each kind at most once, only params that change, tasteful values (most within 40). name is a short English title of 2 to 4 words. note is one short sentence in the user's language about what you did. If earlier steps of yours are listed, return the full new list that should replace them: keep what still fits and change what the user asks for.
    """

    static let nameSystem = """
    Podaj krótką, opisową nazwę pliku po polsku dla tego zdjęcia: od 2 do 5 słów, pierwsza litera wielka, bez rozszerzenia, bez kropek i znaków specjalnych. Pisz poprawną polszczyzną z polskimi znakami (ą, ę, ó, ł, ś, ż), przymiotniki zgodne z rzeczownikiem w rodzaju i przypadku. Odpowiedz samym JSON: {"name":"..."}.
    """

    public func describeLook(prompt: String, preview: Data, previous: [Step]) async throws -> LookAnswer {
        var text = prompt
        if !previous.isEmpty {
            let old = previous.map { step -> [String: Any] in
                ["kind": step.kind.rawValue, "name": step.name, "params": step.params]
            }
            if let data = try? JSONSerialization.data(withJSONObject: old), let json = String(data: data, encoding: .utf8) {
                text += "\n\nYour earlier steps: " + json
            }
        }
        let answer = try await ask(system: Gemini.lookSystem, text: text, image: preview, temperature: 0.4)
        guard let list = answer["steps"] as? [[String: Any]] else { throw AIError.badAnswer }
        var steps: [Step] = []
        for item in list {
            guard let kindText = item["kind"] as? String, let kind = StepKind(rawValue: kindText) else { continue }
            if steps.contains(where: { $0.kind == kind }) { continue }
            var params: [String: Double] = [:]
            for (key, value) in (item["params"] as? [String: Any]) ?? [:] {
                if let n = value as? NSNumber { params[key] = n.doubleValue }
            }
            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let step = Step(kind: kind, name: (name?.isEmpty ?? true) ? nil : name, ai: true, params: params)
            if !step.isNeutral { steps.append(step) }
        }
        guard !steps.isEmpty else { throw AIError.badAnswer }
        return LookAnswer(steps: steps, note: (answer["note"] as? String) ?? "")
    }

    public func suggestName(preview: Data) async throws -> String {
        let answer = try await ask(system: Gemini.nameSystem, text: "Nazwij to zdjęcie.", image: preview, temperature: 0.3)
        let name = Library.cleanName((answer["name"] as? String) ?? "")
        guard !name.isEmpty else { throw AIError.badAnswer }
        return name
    }

    private func ask(system: String, text: String, image: Data, temperature: Double) async throws -> [String: Any] {
        let keys = Gemini.loadKeys()
        guard !keys.isEmpty else { throw AIError.noKey }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [[
                "role": "user",
                "parts": [
                    ["inlineData": ["mimeType": "image/jpeg", "data": image.base64EncodedString()]],
                    ["text": text]
                ]
            ]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": temperature]
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        var last = "Gemini did not answer."
        for model in models {
            var attempt = 0
            while attempt < keys.count * 2 {
                let key = keys[attempt % keys.count]
                attempt += 1
                var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
                request.httpMethod = "POST"
                request.httpBody = payload
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: request)
                } catch {
                    last = error.localizedDescription
                    break
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    if let parsed = Gemini.parse(data) { return parsed }
                    last = "The model answered with something unreadable."
                    break
                }
                let message = String(data: data, encoding: .utf8) ?? ""
                let keyProblem = [401, 403, 429].contains(status) || (status == 400 && message.range(of: "API.?key", options: [.regularExpression, .caseInsensitive]) != nil)
                last = "Gemini answered \(status)."
                if !keyProblem { break }
                if attempt % keys.count == 0 && attempt < keys.count * 2 {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
        throw AIError.offline(last)
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return nil
        }
        var text = parts.compactMap { $0["text"] as? String }.joined()
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
