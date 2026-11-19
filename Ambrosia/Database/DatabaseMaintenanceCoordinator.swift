import Foundation
import Observation
import OSLog

private let maintenanceLogger = Logger(subsystem: "com.ambrosia.maintenance", category: "DatabaseMaintenance")

/// Coordinates long-running database maintenance operations (such as vacuuming, FTS indexing, and semantic indexing).
/// Prevents sleep/App Nap during active operations via `NSProcessInfo` activity assertions, tracks operational state,
/// and provides coordination to warn users before app termination.
@MainActor
@Observable
public final class DatabaseMaintenanceCoordinator {
    public static let shared = DatabaseMaintenanceCoordinator()

    public enum MaintenanceKind: Sendable, Hashable {
        case compactAndVacuum
        case indexingFTS
        case semanticIndexing

        public var displayName: String {
            switch self {
            case .compactAndVacuum:
                return "Compacting and vacuuming databases"
            case .indexingFTS:
                return "Indexing full-text search"
            case .semanticIndexing:
                return "Generating semantic search index"
            }
        }
    }

    public struct MaintenanceOperation: Identifiable, Sendable {
        public let id: UUID
        public let kind: MaintenanceKind
        public let detail: String
        public let startedAt: Date
        fileprivate let onCancel: (@Sendable () -> Void)?

        public init(
            id: UUID = UUID(),
            kind: MaintenanceKind,
            detail: String,
            startedAt: Date = Date(),
            onCancel: (@Sendable () -> Void)? = nil
        ) {
            self.id = id
            self.kind = kind
            self.detail = detail
            self.startedAt = startedAt
            self.onCancel = onCancel
        }
    }

    public private(set) var activeOperations: [UUID: MaintenanceOperation] = [:]
    private var sleepActivity: (any NSObjectProtocol)?

    public var isMaintenanceInProgress: Bool {
        !activeOperations.isEmpty
    }

    public var isCompacting: Bool {
        activeOperations.values.contains { $0.kind == .compactAndVacuum }
    }

    public var isIndexingFTS: Bool {
        activeOperations.values.contains { $0.kind == .indexingFTS }
    }

    public var isIndexingSemantic: Bool {
        activeOperations.values.contains { $0.kind == .semanticIndexing }
    }

    /// Formatted human-readable summary of ongoing maintenance operations.
    public var currentSummary: String? {
        guard !activeOperations.isEmpty else { return nil }
        let names = Set(activeOperations.values.map(\.kind.displayName))
        return names.sorted().joined(separator: ", ")
    }

    public init() {}

    /// Registers the beginning of a maintenance operation and acquires a sleep prevention activity if needed.
    /// Returns a UUID token that must be passed to `endOperation(id:)`.
    @discardableResult
    public func beginOperation(
        kind: MaintenanceKind,
        detail: String = "",
        onCancel: (@Sendable () -> Void)? = nil
    ) -> UUID {
        let op = MaintenanceOperation(
            id: UUID(),
            kind: kind,
            detail: detail,
            startedAt: Date(),
            onCancel: onCancel
        )
        activeOperations[op.id] = op
        updateActivityState()
        maintenanceLogger.info("Started database maintenance: \(kind.displayName, privacy: .public) (\(op.id.uuidString, privacy: .public))")
        return op.id
    }

    /// Marks a maintenance operation as finished and releases the sleep activity if no operations remain.
    public func endOperation(id: UUID) {
        guard let op = activeOperations.removeValue(forKey: id) else { return }
        updateActivityState()
        let duration = String(format: "%.1fs", Date().timeIntervalSince(op.startedAt))
        maintenanceLogger.info("Finished database maintenance: \(op.kind.displayName, privacy: .public) in \(duration, privacy: .public)")
    }

    /// Cancels all active operations that registered a cancellation handler.
    public func cancelAll() {
        maintenanceLogger.warning("Cancelling all active database maintenance operations (\(self.activeOperations.count))")
        let ops = Array(activeOperations.values)
        for op in ops {
            op.onCancel?()
        }
    }

    /// Runs an asynchronous operation within the scope of a maintenance token.
    public func withMaintenance<T>(
        kind: MaintenanceKind,
        detail: String = "",
        onCancel: (@Sendable () -> Void)? = nil,
        work: () async throws -> T
    ) async rethrows -> T {
        let id = beginOperation(kind: kind, detail: detail, onCancel: onCancel)
        defer { endOperation(id: id) }
        return try await work()
    }

    private func updateActivityState() {
        if !activeOperations.isEmpty {
            if sleepActivity == nil {
                sleepActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled],
                    reason: "Database maintenance in progress"
                )
            }
        } else {
            if let activity = sleepActivity {
                ProcessInfo.processInfo.endActivity(activity)
                sleepActivity = nil
            }
        }
    }
}
