import Foundation
import Combine

@MainActor
final class KnowledgeLibrarySelectionViewModel: ObservableObject {
    struct LibraryImportHealth {
        let failed: Int
        let pending: Int
        let completed: Int
        let imported: Int
        let skipped: Int
    }

    @Published private(set) var libraries: [KnowledgeLibrary] = []
    @Published var selectedLibraryIDs: Set<String>
    @Published private(set) var workspaceLibraryID: String?
    @Published private(set) var importHealthByLibraryID: [String: LibraryImportHealth] = [:]
    @Published private(set) var suggestedLibraryIDs: Set<String> = []
    @Published var searchText = ""
    @Published private(set) var visibleLibraries: [KnowledgeLibrary] = []

    private let conversationID: UUID
    private let store: ConversationStore
    private let service: KnowledgeBaseService
    private var refreshToken = UUID()
    private var cancellables = Set<AnyCancellable>()

    private struct Snapshot {
        let libraries: [KnowledgeLibrary]
        let workspaceLibraryID: String?
        let importHealthByLibraryID: [String: LibraryImportHealth]
        let suggestedLibraryIDs: Set<String>
    }

    init(
        conversationID: UUID,
        store: ConversationStore,
        service: KnowledgeBaseService? = nil
    ) {
        self.conversationID = conversationID
        self.store = store
        self.service = service ?? .shared
        self.selectedLibraryIDs = Set(
            store.conversations.first(where: { $0.id == conversationID })?.knowledgeLibraryIDs ?? []
        )
        bindSearch()
        refresh()
    }

    var isKnowledgeEnabled: Bool {
        !selectedLibraryIDs.isEmpty
    }

    var filteredLibraries: [KnowledgeLibrary] {
        visibleLibraries
    }

    func refresh() {
        let conversation = store.conversations.first(where: { $0.id == conversationID })
        let settingsSnapshot = store.settings
        let refreshToken = UUID()
        self.refreshToken = refreshToken
        let service = self.service

        DispatchQueue.global(qos: .utility).async {
            var libraries = service.listLibraries()
                .sorted { lhs, rhs in
                    if lhs.sourceRoot != nil && rhs.sourceRoot == nil { return true }
                    if lhs.sourceRoot == nil && rhs.sourceRoot != nil { return false }
                    return lhs.updatedAt > rhs.updatedAt
                }

            let importJobs = service.listImportJobs()
            let importHealthByLibraryID = Dictionary(
                grouping: importJobs,
                by: { $0.libraryId.uuidString }
            ).mapValues { jobs in
                let failed = jobs.filter { $0.status == .failed }.count
                let pending = jobs.filter { $0.status == .pending || $0.status == .running }.count
                let completed = jobs.filter { $0.status == .succeeded }.count
                let imported = jobs.reduce(0) { $0 + max(0, $1.importedCount ?? 0) }
                let skipped = jobs.reduce(0) { $0 + max(0, $1.skippedCount ?? 0) }
                return LibraryImportHealth(
                    failed: failed,
                    pending: pending,
                    completed: completed,
                    imported: imported,
                    skipped: skipped
                )
            }

            let workspaceLibraryID: String?
            let suggestedLibraryIDs: Set<String>
            if let conversation {
                let workspacePath = conversation.sandboxDir.isEmpty ? settingsSnapshot.ensureSandboxDir() : conversation.sandboxDir
                let workspaceLibrary = service.ensureLibraryForWorkspace(rootPath: workspacePath)
                workspaceLibraryID = workspaceLibrary.id.uuidString
                if !libraries.contains(where: { $0.id == workspaceLibrary.id }) {
                    libraries.insert(workspaceLibrary, at: 0)
                }
                suggestedLibraryIDs = KnowledgeLibrarySuggestionEngine.suggestedLibraryIDs(
                    workspacePath: workspacePath,
                    libraries: libraries,
                    workspaceLibraryID: workspaceLibraryID
                )
            } else {
                workspaceLibraryID = nil
                suggestedLibraryIDs = []
            }

            let snapshot = Snapshot(
                libraries: libraries,
                workspaceLibraryID: workspaceLibraryID,
                importHealthByLibraryID: importHealthByLibraryID,
                suggestedLibraryIDs: suggestedLibraryIDs
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.refreshToken == refreshToken else { return }
                self.libraries = snapshot.libraries
                self.workspaceLibraryID = snapshot.workspaceLibraryID
                self.importHealthByLibraryID = snapshot.importHealthByLibraryID
                self.suggestedLibraryIDs = snapshot.suggestedLibraryIDs
                self.recomputeVisibleLibraries()
            }
        }
    }

    func setKnowledgeEnabled(_ isEnabled: Bool) {
        if isEnabled {
            if selectedLibraryIDs.isEmpty, let workspaceLibraryID {
                selectedLibraryIDs = [workspaceLibraryID]
            }
        } else {
            selectedLibraryIDs.removeAll()
        }
        recomputeVisibleLibraries()
    }

    func toggleLibrary(_ libraryID: String) {
        if selectedLibraryIDs.contains(libraryID) {
            selectedLibraryIDs.remove(libraryID)
        } else {
            selectedLibraryIDs.insert(libraryID)
        }
        recomputeVisibleLibraries()
    }

    func applySuggestedLibraries() {
        guard !suggestedLibraryIDs.isEmpty else { return }
        selectedLibraryIDs.formUnion(suggestedLibraryIDs)
        recomputeVisibleLibraries()
    }

    func replaceWithSuggestedLibraries() {
        guard !suggestedLibraryIDs.isEmpty else { return }
        selectedLibraryIDs = suggestedLibraryIDs
        recomputeVisibleLibraries()
    }

    func applySelection() {
        let ordered = libraries
            .map { $0.id.uuidString }
            .filter { selectedLibraryIDs.contains($0) }
        store.setConversationKnowledgeLibraries(conversationID, libraryIDs: ordered)
    }

    @discardableResult
    func createLibrary(name: String, sourceRoot: String?) async -> KnowledgeLibrary {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSourceRoot = sourceRoot?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? L10n.tr("settings.knowledge.overview.new.default_name") : trimmedName
        let library = service.createLibrary(
            named: displayName,
            sourceRoot: trimmedSourceRoot?.isEmpty == true ? nil : trimmedSourceRoot
        )
        refresh()
        selectedLibraryIDs.insert(library.id.uuidString)
        recomputeVisibleLibraries()
        return library
    }

    func importHealth(for libraryID: String) -> LibraryImportHealth {
        importHealthByLibraryID[libraryID] ?? LibraryImportHealth(
            failed: 0,
            pending: 0,
            completed: 0,
            imported: 0,
            skipped: 0
        )
    }

    func isSuggestedLibrary(_ libraryID: String) -> Bool {
        suggestedLibraryIDs.contains(libraryID)
    }

    var conversationStore: ConversationStore {
        store
    }

    private func bindSearch() {
        $searchText
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.recomputeVisibleLibraries()
            }
            .store(in: &cancellables)
    }

    private func recomputeVisibleLibraries() {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = libraries.sorted(by: shouldSortLibrary)
        guard !needle.isEmpty else {
            visibleLibraries = base
            return
        }

        visibleLibraries = base.filter { library in
            [
                library.name,
                library.sourceRoot ?? "",
                library.id.uuidString
            ].contains { $0.lowercased().contains(needle) }
        }
    }

    private func shouldSortLibrary(_ lhs: KnowledgeLibrary, _ rhs: KnowledgeLibrary) -> Bool {
        let lhsID = lhs.id.uuidString
        let rhsID = rhs.id.uuidString

        let lhsSuggested = suggestedLibraryIDs.contains(lhsID)
        let rhsSuggested = suggestedLibraryIDs.contains(rhsID)
        if lhsSuggested != rhsSuggested {
            return lhsSuggested && !rhsSuggested
        }

        let lhsWorkspace = lhsID == workspaceLibraryID
        let rhsWorkspace = rhsID == workspaceLibraryID
        if lhsWorkspace != rhsWorkspace {
            return lhsWorkspace && !rhsWorkspace
        }

        let lhsSelected = selectedLibraryIDs.contains(lhsID)
        let rhsSelected = selectedLibraryIDs.contains(rhsID)
        if lhsSelected != rhsSelected {
            return lhsSelected && !rhsSelected
        }

        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
