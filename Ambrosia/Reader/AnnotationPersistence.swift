import Foundation
import AppKit

/// Manages asynchronous persistence for reader annotations with rollback on failure
/// and error logging to `error_log` (F3 Class A).
@MainActor
final class AnnotationPersistence {
    typealias InsertHandler = (Annotation, Int) async throws -> Void
    typealias DeleteHandler = (UUID, Int) async throws -> Void

    private let insertHandler: InsertHandler
    private let deleteHandler: DeleteHandler
    private weak var metaDB: AmbrosiaMetaDB?

    init(
        metaDB: AmbrosiaMetaDB?,
        insertHandler: @escaping InsertHandler,
        deleteHandler: @escaping DeleteHandler
    ) {
        self.metaDB = metaDB
        self.insertHandler = insertHandler
        self.deleteHandler = deleteHandler
    }

    convenience init(metaDB: AmbrosiaMetaDB?) {
        self.init(
            metaDB: metaDB,
            insertHandler: { annotation, calibreID in
                try await metaDB?.insertAnnotation(annotation, calibreID: calibreID)
            },
            deleteHandler: { id, calibreID in
                try await metaDB?.deleteAnnotation(id: id, calibreID: calibreID)
            }
        )
    }

    /// Persists an inserted annotation asynchronously, executing `onRollback` if persistence fails.
    func saveAnnotation(
        _ annotation: Annotation,
        calibreID: Int,
        onRollback: @escaping () -> Void
    ) {
        Task {
            do {
                try await insertHandler(annotation, calibreID)
                if let path = AppDelegate.shared?.session.activePath, let metaDB {
                    await AnnotationBackupManager.shared.scheduleDirtyBackup(
                        calibreID: calibreID,
                        libraryURL: URL(fileURLWithPath: path),
                        metaDB: metaDB
                    )
                }
            } catch {
                _ = try? await metaDB?.logError(
                    subsystem: "Reader",
                    operation: "insertAnnotation",
                    message: "Failed to persist annotation: \(error.localizedDescription)",
                    calibreID: calibreID
                )
                onRollback()
                presentErrorAlert(message: "Failed to save annotation: \(error.localizedDescription)")
            }
        }
    }

    /// Deletes an annotation asynchronously, executing `onRollback` if removal fails.
    func removeAnnotation(
        id: UUID,
        calibreID: Int,
        onRollback: @escaping () -> Void
    ) {
        Task {
            do {
                try await deleteHandler(id, calibreID)
                if let path = AppDelegate.shared?.session.activePath, let metaDB {
                    await AnnotationBackupManager.shared.scheduleDirtyBackup(
                        calibreID: calibreID,
                        libraryURL: URL(fileURLWithPath: path),
                        metaDB: metaDB
                    )
                }
            } catch {
                _ = try? await metaDB?.logError(
                    subsystem: "Reader",
                    operation: "deleteAnnotation",
                    message: "Failed to delete annotation: \(error.localizedDescription)",
                    calibreID: calibreID
                )
                onRollback()
                presentErrorAlert(message: "Failed to delete annotation: \(error.localizedDescription)")
            }
        }
    }

    private func presentErrorAlert(message: String) {
        guard !AppEnvironment.isRunningTests else { return }
        let alert = NSAlert()
        alert.messageText = "Annotation Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
