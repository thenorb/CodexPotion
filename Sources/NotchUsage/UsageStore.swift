import Foundation

struct ProviderUsage: Codable, Equatable {
    var remainingPercent: Double
    var label: String?
    var resetsAt: Date?
    var secondaryRemainingPercent: Double? = nil
    var secondaryLabel: String? = nil
    var secondaryResetsAt: Date? = nil

    static let placeholder = ProviderUsage(remainingPercent: -1, label: "等待实时数据", resetsAt: nil)
}

private struct UsageDocument: Codable {
    var claude: ProviderUsage
    var codex: ProviderUsage
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var claude = ProviderUsage.placeholder
    @Published private(set) var codex = ProviderUsage.placeholder
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?

    private var timer: Timer?
    private var lastClaudePoll: Date?
    private var lastCodexRemotePoll: Date?
    private var hasAuthoritativeCodexUsage = false
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    let configURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".notch-usage", isDirectory: true)
        .appendingPathComponent("usage.json")

    func start() {
        ensureConfigExists()
        loadCachedLiveUsage()
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh(force: Bool = false) async {
        // Query Codex's authoritative service on manual refresh and once per
        // minute. Local session data is only a fallback until that first success.
        let shouldPollCodexRemote = force
            || lastCodexRemotePoll == nil
            || Date().timeIntervalSince(lastCodexRemotePoll!) >= 59
        if shouldPollCodexRemote {
            lastCodexRemotePoll = .now
            if let remoteCodex = await remoteCodexUsage() {
                codex = sanitize(remoteCodex)
                hasAuthoritativeCodexUsage = true
                cache(codex, key: "liveCodexUsage")
            } else if !hasAuthoritativeCodexUsage, let localCodex = localCodexUsage() {
                codex = sanitize(localCodex)
                cache(codex, key: "liveCodexUsage")
            }
        } else if !hasAuthoritativeCodexUsage, let localCodex = localCodexUsage() {
            // Session logs are only a startup/offline fallback. Once the service
            // has answered, they may contain an older reset time and must never
            // overwrite the authoritative value.
            codex = sanitize(localCodex)
            cache(codex, key: "liveCodexUsage")
        }

        if force || lastClaudePoll == nil || Date().timeIntervalSince(lastClaudePoll!) >= 59 {
            if let liveClaude = await localClaudeUsage() {
                claude = sanitize(liveClaude)
                cache(claude, key: "liveClaudeUsage")
            }
            lastClaudePoll = .now
        }

        lastUpdated = .now
        errorMessage = claude.remainingPercent < 0 || codex.remainingPercent < 0
            ? "部分实时用量暂不可用"
            : nil
    }

    func ensureConfigExists() {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let sample = """
            {
              "claude": {
                "remainingPercent": 72,
                "label": "5 小时窗口",
                "resetsAt": "2026-07-26T02:00:00Z"
              },
              "codex": {
                "remainingPercent": 43,
                "label": "每周额度",
                "resetsAt": "2026-07-28T04:00:00Z"
              }
            }
            """
            try sample.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "无法创建配置文件"
        }
    }

    private func sanitize(_ usage: ProviderUsage) -> ProviderUsage {
        var result = usage
        result.remainingPercent = min(100, max(0, result.remainingPercent))
        if let secondary = result.secondaryRemainingPercent {
            result.secondaryRemainingPercent = min(100, max(0, secondary))
        }
        return result
    }

    private func cache(_ usage: ProviderUsage, key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(usage) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadCachedLiveUsage() {
        if let data = UserDefaults.standard.data(forKey: "liveClaudeUsage"),
           let cached = try? decoder.decode(ProviderUsage.self, from: data) {
            claude = cached
        }
        if let data = UserDefaults.standard.data(forKey: "liveCodexUsage"),
           let cached = try? decoder.decode(ProviderUsage.self, from: data) {
            codex = cached
        }
    }

    private func localCodexUsage() -> ProviderUsage? {
        let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let files = enumerator.compactMap { item -> (URL, Date)? in
            guard let url = item as? URL, url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else { return nil }
            return (url, date)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(5)

        for (url, _) in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\":{") {
                guard let data = String(line).data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = root["payload"] as? [String: Any],
                      let limits = payload["rate_limits"] as? [String: Any],
                      let primary = limits["primary"] as? [String: Any],
                      let used = primary["used_percent"] as? Double else { continue }

                let minutes = primary["window_minutes"] as? Int
                let resetSeconds = primary["resets_at"] as? TimeInterval
                let windowLabel: String
                if let minutes, minutes >= 10080 {
                    windowLabel = "每周额度 · 实时"
                } else if let minutes {
                    windowLabel = "\(minutes / 60) 小时窗口 · 实时"
                } else {
                    windowLabel = "Codex 本地会话 · 实时"
                }
                return ProviderUsage(
                    remainingPercent: 100 - used,
                    label: windowLabel,
                    resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:))
                )
            }
        }
        return nil
    }

    private func remoteCodexUsage() async -> ProviderUsage? {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let authData = try? Data(contentsOf: authURL),
              let auth = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let accountID = tokens["account_id"] as? String else { return nil }

        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rateLimit = root["rate_limit"] as? [String: Any],
                  let primary = rateLimit["primary_window"] as? [String: Any],
                  let used = primary["used_percent"] as? Double else { return nil }

            let resetSeconds = primary["reset_at"] as? TimeInterval
            let windowSeconds = primary["limit_window_seconds"] as? Int
            let label = (windowSeconds ?? 0) >= 604800
                ? "每周额度 · 服务端实时"
                : "当前额度 · 服务端实时"
            return ProviderUsage(
                remainingPercent: 100 - used,
                label: label,
                resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:))
            )
        } catch {
            return nil
        }
    }

    private func localClaudeUsage() async -> ProviderUsage? {
        guard let accessToken = claudeAccessToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fiveHour = root["five_hour"] as? [String: Any],
                  let sevenDay = root["seven_day"] as? [String: Any],
                  let fiveHourUsed = fiveHour["utilization"] as? Double,
                  let sevenDayUsed = sevenDay["utilization"] as? Double else { return nil }

            let fiveReset = fiveHour["resets_at"] as? String
            let weekReset = sevenDay["resets_at"] as? String
            let isoFormatter = ISO8601DateFormatter()
            return ProviderUsage(
                remainingPercent: 100 - sevenDayUsed,
                label: "每周额度 · 实时",
                resetsAt: weekReset.flatMap(isoFormatter.date(from:)),
                secondaryRemainingPercent: 100 - fiveHourUsed,
                secondaryLabel: "5 小时窗口 · 实时",
                secondaryResetsAt: fiveReset.flatMap(isoFormatter.date(from:))
            )
        } catch {
            return nil
        }
    }

    private func claudeAccessToken() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-w"
        ]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = root["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String,
                  !token.isEmpty else { return nil }
            return token
        } catch {
            return nil
        }
    }
}
