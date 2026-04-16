import Foundation

enum KnowledgeLibrarySuggestionEngine {
    nonisolated static func suggestedLibraryIDs(
        workspacePath: String,
        libraries: [KnowledgeLibrary],
        workspaceLibraryID: String?
    ) -> Set<String> {
        let normalizedWorkspace = AppStoragePaths.normalizeSandboxPath(workspacePath)
        guard !normalizedWorkspace.isEmpty else { return [] }

        let workspaceTail = URL(fileURLWithPath: normalizedWorkspace, isDirectory: true)
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let workspaceTokens = routeTokens(from: workspaceTail)

        let ranked = libraries.compactMap { library -> (id: String, score: Double)? in
            let id = library.id.uuidString
            var score = 0.0

            if id == workspaceLibraryID {
                score += 10
            }

            if let sourceRoot = library.sourceRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sourceRoot.isEmpty {
                let normalizedSource = AppStoragePaths.normalizeSandboxPath(sourceRoot)
                if normalizedSource == normalizedWorkspace {
                    score += 8
                } else if normalizedSource.hasPrefix(normalizedWorkspace + "/") || normalizedWorkspace.hasPrefix(normalizedSource + "/") {
                    score += 5
                }

                let sourceTail = URL(fileURLWithPath: normalizedSource, isDirectory: true).lastPathComponent.lowercased()
                if !workspaceTail.isEmpty && sourceTail == workspaceTail {
                    score += 2.5
                }

                let overlap = routeTokens(from: sourceTail).intersection(workspaceTokens).count
                score += Double(overlap) * 0.6
            } else {
                let overlap = routeTokens(from: library.name).intersection(workspaceTokens).count
                score += Double(overlap) * 0.45
            }

            if library.documentCount > 0 && library.chunkCount > 0 {
                score += 0.35
            }

            if library.status == .failed {
                score -= 1.2
            }

            guard score >= 2.0 else { return nil }
            return (id: id, score: score)
        }
        .sorted {
            if $0.score == $1.score {
                return $0.id < $1.id
            }
            return $0.score > $1.score
        }

        return Set(ranked.prefix(3).map(\.id))
    }

    nonisolated private static func routeTokens(from text: String) -> Set<String> {
        let lowercased = text.lowercased()
        let scalars = lowercased.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let normalized = String(scalars)
        return Set(
            normalized
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 2 }
        )
    }
}
