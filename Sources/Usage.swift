import Foundation

struct Limit {
    let id: String
    let title: String
    let used: Double
    let severity: String
    let resetsAt: Date?

    var left: Double { 100 - used }
    func shown(_ showLeft: Bool) -> Double { showLeft ? left : used }
}

struct Usage {
    let limits: [Limit]
    let plan: String?
    let fetchedAt = Date()

    var session: Limit? { limits.first { $0.id == "session" } ?? limits.first }
    var weekly: Limit? { limits.first { $0.id == "weekly_all" } ?? limits.first { $0.id.hasPrefix("weekly") } }
}

enum UsageError: LocalizedError {
    case noLogin, unauthorized, rateLimited(TimeInterval?), http(Int), other(String)

    var errorDescription: String? {
        switch self {
        case .noLogin: return "No Claude Code login found. Run `claude` and sign in."
        case .unauthorized: return "Token expired. Run `claude` once to refresh it."
        case .rateLimited: return "Usage API is rate limiting. Retrying later."
        case .http(let code): return "Usage API returned HTTP \(code)."
        case .other(let message): return message
        }
    }
}

enum UsageClient {
    static func fetch(_ done: @escaping (Result<Usage, UsageError>) -> Void) {
        let finish = { result in DispatchQueue.main.async { done(result) } }
        DispatchQueue.global().async {
            guard let oauth = credentials(), let token = oauth["accessToken"] as? String else {
                return finish(.failure(.noLogin))
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
                if let error { return finish(.failure(.other(error.localizedDescription))) }
                let http = response as? HTTPURLResponse
                switch http?.statusCode ?? 0 {
                case 200: break
                case 401, 403: return finish(.failure(.unauthorized))
                case 429: return finish(.failure(.rateLimited(http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))))
                case let code: return finish(.failure(.http(code)))
                }
                guard let json = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] else {
                    return finish(.failure(.other("Unexpected response from the usage API.")))
                }
                finish(.success(Usage(limits: limits(json), plan: oauth["subscriptionType"] as? String)))
            }.resume()
        }
    }

    private static func credentials() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = nil
        try? process.run()
        var data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 || data.isEmpty {
            data = (try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json"))) ?? Data()
        }
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return root?["claudeAiOauth"] as? [String: Any]
    }

    private static func limits(_ json: [String: Any]) -> [Limit] {
        let list = (json["limits"] as? [[String: Any]] ?? []).compactMap { item -> Limit? in
            guard let kind = item["kind"] as? String, let percent = item["percent"] as? Double else { return nil }
            let model = ((item["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            return Limit(id: model.map { "\(kind):\($0)" } ?? kind,
                         title: title(kind, model),
                         used: min(max(percent, 0), 100),
                         severity: item["severity"] as? String ?? "",
                         resetsAt: date(item["resets_at"]))
        }
        if !list.isEmpty { return list }
        let windows = [("session", "five_hour"), ("weekly_all", "seven_day"),
                       ("weekly_scoped:Opus", "seven_day_opus"), ("weekly_scoped:Sonnet", "seven_day_sonnet")]
        return windows.compactMap { id, key in
            guard let window = json[key] as? [String: Any], let used = window["utilization"] as? Double else { return nil }
            let parts = id.split(separator: ":").map(String.init)
            return Limit(id: id, title: title(parts[0], parts.count > 1 ? parts[1] : nil),
                         used: min(max(used, 0), 100), severity: "", resetsAt: date(window["resets_at"]))
        }
    }

    private static func title(_ kind: String, _ model: String?) -> String {
        switch kind {
        case "session": return "Session (5h)"
        case "weekly_all": return "Weekly (all models)"
        case "weekly_scoped": return "Weekly · \(model ?? "scoped")"
        default: return [kind.replacingOccurrences(of: "_", with: " ").capitalized, model].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let stripped = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: stripped)
    }
}
