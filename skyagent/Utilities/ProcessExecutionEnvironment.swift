import Foundation

final class ProcessExecutionEnvironment: @unchecked Sendable {
    nonisolated static let shared = ProcessExecutionEnvironment()

    private let lock = NSLock()
    nonisolated(unsafe) private var cachedStartupEnvironment: [String: String]?
    nonisolated(unsafe) private var isWarmupInFlight = false

    private init() {}

    nonisolated func resolvedEnvironment(
        additional: [String: String] = [:],
        prependPathEntries: [String] = []
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        let startupEnvironmentSnapshot = startupEnvironment()
        if startupEnvironmentSnapshot.isEmpty {
            preloadEnvironmentIfNeeded()
        }

        for (key, value) in startupEnvironmentSnapshot where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environment[key] = value
        }

        for (key, value) in additional {
            environment[key] = value
        }

        let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        var pathSegments = normalizedPathSegments(from: environment["PATH"] ?? defaultPath)
        for segment in normalizedPathSegments(from: defaultPath) where !pathSegments.contains(segment) {
            pathSegments.append(segment)
        }
        for entry in prependPathEntries.reversed() where !entry.isEmpty && !pathSegments.contains(entry) {
            pathSegments.insert(entry, at: 0)
        }
        environment["PATH"] = pathSegments.joined(separator: ":")

        return environment
    }

    nonisolated func preloadEnvironmentIfNeeded() {
        lock.lock()
        let shouldStart = cachedStartupEnvironment == nil && !isWarmupInFlight
        if shouldStart {
            isWarmupInFlight = true
        }
        lock.unlock()

        guard shouldStart else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let environment = await self.loadStartupEnvironmentAsync()
            self.storeWarmupResult(environment)
        }
    }

    nonisolated func resolveCommandPath(_ command: String, environment: [String: String]) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }

        let searchPaths = normalizedPathSegments(from: environment["PATH"] ?? "")
        for directory in searchPaths {
            let candidate = (directory as NSString).appendingPathComponent(trimmed)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    nonisolated private func startupEnvironment() -> [String: String] {
        lock.lock()
        if let cachedStartupEnvironment {
            lock.unlock()
            return cachedStartupEnvironment
        }
        lock.unlock()
        return [:]
    }

    nonisolated private func preferredShells() -> [String] {
        let candidates = [
            ProcessInfo.processInfo.environment["SHELL"],
            "/bin/zsh",
            "/bin/bash"
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }

        var unique: [String] = []
        for candidate in candidates where !candidate.isEmpty && !unique.contains(candidate) {
            unique.append(candidate)
        }
        return unique
    }

    private func loadStartupEnvironmentAsync() async -> [String: String] {
        var merged: [String: String] = [:]
        for shellPath in preferredShells() {
            let environment = await loadEnvironment(shellPath: shellPath)
            for (key, value) in environment where !value.isEmpty {
                merged[key] = value
            }
        }
        return merged
    }

    nonisolated private func storeWarmupResult(_ environment: [String: String]) {
        lock.lock()
        cachedStartupEnvironment = environment
        isWarmupInFlight = false
        lock.unlock()
    }

    private func loadEnvironment(shellPath: String) async -> [String: String] {
        guard FileManager.default.isExecutableFile(atPath: shellPath) else { return [:] }

        do {
            let result = try await AsyncProcessRunner.shared.run(
                executableURL: URL(fileURLWithPath: shellPath),
                arguments: [
                    "-lc",
                    startupCommand(for: shellPath)
                ],
                timeout: 3
            )
            guard result.terminationStatus == 0 else { return [:] }
            let data = result.stdout
            guard let raw = String(data: data, encoding: .utf8) else { return [:] }

            var environment: [String: String] = [:]
            for entry in raw.split(separator: "\0") {
                guard let separator = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<separator])
                let value = String(entry[entry.index(after: separator)...])
                environment[key] = value
            }
            return environment
        } catch {
            return [:]
        }
    }

    nonisolated private func startupCommand(for shellPath: String) -> String {
        if shellPath.hasSuffix("zsh") {
            return "source ~/.zshenv >/dev/null 2>&1 || true; source ~/.zprofile >/dev/null 2>&1 || true; source ~/.zshrc >/dev/null 2>&1 || true; source ~/.zlogin >/dev/null 2>&1 || true; source ~/.profile >/dev/null 2>&1 || true; env -0"
        }

        return "source ~/.bashrc >/dev/null 2>&1 || true; source ~/.bash_profile >/dev/null 2>&1 || true; source ~/.profile >/dev/null 2>&1 || true; env -0"
    }

    nonisolated private func normalizedPathSegments(from value: String) -> [String] {
        value
            .split(separator: ":")
            .map(String.init)
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { !$0.isEmpty }
    }
}
