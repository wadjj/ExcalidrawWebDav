//
//  SyncModels.swift
//  ExcalidrawZ
//
//  Created by Claude on 2025/12/31.
//

import Foundation

/// Sync operation type
enum SyncOperation: Codable, CustomStringConvertible {
    case uploadToRemote      // Local → Remote backend
    case downloadFromRemote  // Remote backend → Local
    case deleteFromRemote    // Remove from remote backend
    case deleteFromLocal     // Remove from local

    private enum CodingValues: String, Codable {
        case uploadToRemote
        case downloadFromRemote
        case deleteFromRemote
        case deleteFromLocal

        // Backward compatibility with previously persisted queue payloads
        case uploadToCloud
        case downloadFromCloud
        case deleteFromCloud
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(CodingValues.self)
        switch value {
            case .uploadToRemote, .uploadToCloud:
                self = .uploadToRemote
            case .downloadFromRemote, .downloadFromCloud:
                self = .downloadFromRemote
            case .deleteFromRemote, .deleteFromCloud:
                self = .deleteFromRemote
            case .deleteFromLocal:
                self = .deleteFromLocal
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: CodingValues = switch self {
            case .uploadToRemote: .uploadToRemote
            case .downloadFromRemote: .downloadFromRemote
            case .deleteFromRemote: .deleteFromRemote
            case .deleteFromLocal: .deleteFromLocal
        }
        try container.encode(value)
    }

    var description: String {
        switch self {
            case .uploadToRemote: return "upload to remote"
            case .downloadFromRemote: return "download from remote"
            case .deleteFromRemote: return "delete from remote"
            case .deleteFromLocal: return "delete from local"
        }
    }
}

/// Sync priority
/// - high: User-triggered operations (activeFile changes) - processed immediately
/// - normal: Background operations (DiffScan) - processed after high priority tasks
enum SyncPriority: Int, Codable, Comparable {
    case normal = 0
    case high = 1

    static func < (lhs: SyncPriority, rhs: SyncPriority) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/// Sync event with operation details
struct SyncEvent: Codable, Identifiable {
    let id: UUID
    let fileID: String
    let relativePath: String
    let operation: SyncOperation
    let timestamp: Date
    let retryCount: Int
    let priority: SyncPriority

    init(
        fileID: String,
        relativePath: String,
        operation: SyncOperation,
        timestamp: Date = Date(),
        retryCount: Int = 0,
        priority: SyncPriority = .normal
    ) {
        self.id = UUID()
        self.fileID = fileID
        self.relativePath = relativePath
        self.operation = operation
        self.timestamp = timestamp
        self.retryCount = retryCount
        self.priority = priority
    }

    /// Create a new event with incremented retry count
    func withIncrementedRetry() -> SyncEvent {
        return SyncEvent(
            fileID: fileID,
            relativePath: relativePath,
            operation: operation,
            timestamp: timestamp,
            retryCount: retryCount + 1,
            priority: priority
        )
    }
}

/// File state for synchronization comparison
struct SyncFileState: Equatable, Hashable {
    let fileID: String
    let relativePath: String
    let contentType: FileStorageContentType
    let modifiedAt: Date
    let size: Int64
    let versionToken: String?
    let remoteSyncState: RemoteSyncState?

    enum Location {
        case local
        case iCloud
    }

    /// Remote file availability state (backend metadata, optional)
    enum RemoteSyncState: Equatable, Hashable {
        case notDownloaded  // File not downloaded (placeholder only)
        case staleLocalCopy // File downloaded but remote has update
        case current        // File is up-to-date
    }

    /// Composite key for unique identification
    var compositeKey: String {
        return "\(fileID):\(contentType.description)"
    }

    init(
        fileID: String,
        relativePath: String,
        contentType: FileStorageContentType,
        modifiedAt: Date,
        size: Int64,
        versionToken: String? = nil,
        remoteSyncState: RemoteSyncState? = nil
    ) {
        self.fileID = fileID
        self.relativePath = relativePath
        self.contentType = contentType
        self.modifiedAt = modifiedAt
        self.size = size
        self.versionToken = versionToken
        self.remoteSyncState = remoteSyncState
    }
}
