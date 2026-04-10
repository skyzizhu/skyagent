import Foundation

final class ProcessExecutionEnvironment: @unchecked Sendable {
    nonisolated static let shared = ProcessExecutionEnvironment()

    private let lock = NSLock()
    nonisolated(unsafe) private var cachedStartupEnvironment: [String: String]?

    private init() {}

    nonisolated func resolvedEnvironment(
        additional: [String: String] = [:],
        prependPathEntries: [String] = []
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        for (key, value) in startupEnvironment() where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

        var merged: [String: String] = [:]
        for shellPath in preferredShells() {
            for (key, value) in loadEnvironment(shellPath: shellPath) where !value.isEmpty {
                merged[key] = value
            }
        }

        lock.lock()
        cachedStartupEnvironment = merged
        lock.unlock()
        return merged
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

    nonisolated private func loadEnvironment(shellPath: String) -> [String: String] {
        guard FileManager.default.isExecutableFile(atPath: shellPath) else { return [:] }

        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = [
            "-lc",
            startupCommand(for: shellPath)
        ]
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
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
