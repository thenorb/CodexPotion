import Foundation
import AppKit

struct ResetCredit: Codable, Equatable, Sendable {
    var title: String
    var expiresAt: Date?
}

struct ProviderUsage: Codable, Equatable, Sendable {
    var remainingPercent: Double
    var label: String?
    var resetsAt: Date?
    var secondaryRemainingPercent: Double? = nil
    var secondaryLabel: String? = nil
    var secondaryResetsAt: Date? = nil
    var availableResetCount: Int? = nil
    var resetCredits: [ResetCredit]? = nil

    var limitingRemainingPercent: Double {
        guard let secondaryRemainingPercent else { return remainingPercent }
        return min(remainingPercent, secondaryRemainingPercent)
    }

    static let placeholder = ProviderUsage(
        remainingPercent: -1,
        label: "Waiting for Codex usage",
        resetsAt: nil
    )
}

@MainActor
final class UsageStore: ObservableObject {
    static let allowedRefreshIntervals: [TimeInterval] = [
        30, 60, 120, 180, 240, 300, 600, 900, 1_200, 1_800, 2_700, 3_600
    ]

    @Published private(set) var codex = ProviderUsage.placeholder
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var refreshInterval: TimeInterval

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var isRefreshing = false
    private static let refreshIntervalKey = "refreshIntervalSeconds"

    init() {
        let savedInterval = UserDefaults.standard.double(forKey: Self.refreshIntervalKey)
        refreshInterval = Self.allowedRefreshIntervals.contains(savedInterval)
            ? savedInterval
            : 300
    }

    func start() {
        loadCachedUsage()
        Task { await refresh() }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.refresh(force: true)
                }
            }
        }
        scheduleTimer()
    }

    func adjustRefreshInterval(by offset: Int) {
        guard let currentIndex = Self.allowedRefreshIntervals.firstIndex(of: refreshInterval) else {
            setRefreshInterval(300)
            return
        }
        let newIndex = min(
            Self.allowedRefreshIntervals.count - 1,
            max(0, currentIndex + offset)
        )
        guard newIndex != currentIndex else { return }
        setRefreshInterval(Self.allowedRefreshIntervals[newIndex])
    }

    private func setRefreshInterval(_ interval: TimeInterval) {
        guard Self.allowedRefreshIntervals.contains(interval) else { return }
        refreshInterval = interval
        UserDefaults.standard.set(interval, forKey: Self.refreshIntervalKey)
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if let usage = await Self.fetchCodexUsage() {
            codex = usage
            cache(usage)
            lastUpdated = Date()
            errorMessage = nil
        } else {
            errorMessage = "Codex usage is temporarily unavailable."
        }
    }

    private func cache(_ usage: ProviderUsage) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(usage) {
            UserDefaults.standard.set(data, forKey: "liveCodexUsage")
        }
    }

    private func loadCachedUsage() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: "liveCodexUsage"),
           let cached = try? decoder.decode(ProviderUsage.self, from: data) {
            codex = cached
        }
    }

    nonisolated private static func fetchCodexUsage() async -> ProviderUsage? {
        await Task.detached(priority: .utility) { () -> ProviderUsage? in
            guard let executable = codexExecutable() else {
                return nil
            }

            let process = Process()
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = executable
            process.arguments = ["app-server"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors

            do {
                try process.run()
                let requests = [
                    #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"codex_potion","title":"Codex Potion","version":"0.1.0"}}}"#,
                    #"{"method":"initialized","params":{}}"#,
                    #"{"method":"account/rateLimits/read","id":1}"#
                ].joined(separator: "\n") + "\n"
                try input.fileHandleForWriting.write(contentsOf: Data(requests.utf8))

                var fetchedUsage: ProviderUsage?
                for try await line in output.fileHandleForReading.bytes.lines {
                    guard let data = line.data(using: .utf8),
                          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          root["id"] as? Int == 1,
                          let result = root["result"] as? [String: Any] else { continue }
                    fetchedUsage = usage(from: result)
                    break
                }

                try? input.fileHandleForWriting.close()
                if process.isRunning {
                    process.terminate()
                }
                process.waitUntilExit()
                return fetchedUsage
            } catch {
                try? input.fileHandleForWriting.close()
                if process.isRunning {
                    process.terminate()
                }
                return nil
            }
        }.value
    }

    nonisolated private static func codexExecutable() -> URL? {
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    nonisolated private static func usage(from result: [String: Any]) -> ProviderUsage? {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let snapshot = (buckets?["codex"] as? [String: Any])
            ?? (result["rateLimits"] as? [String: Any])
        guard let snapshot else { return nil }

        let resetCreditSnapshot = result["rateLimitResetCredits"] as? [String: Any]
        let availableResetCount = number(resetCreditSnapshot?["availableCount"]).map(Int.init)
        let resetCredits = (resetCreditSnapshot?["credits"] as? [[String: Any]])?
            .filter { ($0["status"] as? String) == "available" }
            .map { credit in
                ResetCredit(
                    title: (credit["title"] as? String) ?? "Full reset",
                    expiresAt: number(credit["expiresAt"])
                        .map(Date.init(timeIntervalSince1970:))
                )
            }

        var windows: [(remaining: Double, reset: Date?, label: String)] = []
        for key in ["primary", "secondary"] {
            guard let window = snapshot[key] as? [String: Any],
                  let used = number(window["usedPercent"]) else { continue }
            let minutes = number(window["windowDurationMins"]).map(Int.init)
            let reset = number(window["resetsAt"]).map(Date.init(timeIntervalSince1970:))
            let label: String
            if let minutes, minutes >= 10_080 {
                label = "Weekly window"
            } else if let minutes, minutes >= 60 {
                label = "\(minutes / 60)-hour window"
            } else if let minutes {
                label = "\(minutes)-minute window"
            } else {
                label = "Current window"
            }
            windows.append((min(100, max(0, 100 - used)), reset, label))
        }

        guard let primary = windows.first else { return nil }
        let secondary = windows.dropFirst().first
        return ProviderUsage(
            remainingPercent: primary.remaining,
            label: primary.label,
            resetsAt: primary.reset,
            secondaryRemainingPercent: secondary?.remaining,
            secondaryLabel: secondary?.label,
            secondaryResetsAt: secondary?.reset,
            availableResetCount: availableResetCount,
            resetCredits: resetCredits
        )
    }

    nonisolated private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}
