//
//  SyncModels.swift
//  ExcalidrawZ
//
//  Created by Claude on 2025/12/31.
//

import Foundation

/// Sync operation type
enum SyncOperation: Codable, CustomStringConvertible {
    case uploadToCloud      // Local → iCloud
    case downloadFromCloud  // iCloud → Local
    case deleteFromCloud    // Remove from iCloud
    case deleteFromLocal    // Remove from local

    var description: String {
        switch self {
            case .uploadToCloud: return "upload to cloud"
            case .downloadFromCloud: return "download from cloud"
            case .deleteFromCloud: return "delete from cloud"
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
    let nextAttemptAt: Date?

    init(
        fileID: String,
        relativePath: String,
        operation: SyncOperation,
        timestamp: Date = Date(),
        retryCount: Int = 0,
        priority: SyncPriority = .normal,
        nextAttemptAt: Date? = nil
    ) {
        self.id = UUID()
        self.fileID = fileID
        self.relativePath = relativePath
        self.operation = operation
        self.timestamp = timestamp
        self.retryCount = retryCount
        self.priority = priority
        self.nextAttemptAt = nextAttemptAt
    }

    /// Create a new event with incremented retry count
    func withIncrementedRetry() -> SyncEvent {
        return SyncEvent(
            fileID: fileID,
            relativePath: relativePath,
            operation: operation,
            timestamp: timestamp,
            retryCount: retryCount + 1,
            priority: priority,
            nextAttemptAt: nil
        )
    }

    /// Create a retry event with explicit backoff delay
    func withRetryDelay(_ delay: TimeInterval) -> SyncEvent {
        SyncEvent(
            fileID: fileID,
            relativePath: relativePath,
            operation: operation,
            timestamp: timestamp,
            retryCount: retryCount + 1,
            priority: priority,
            nextAttemptAt: Date().addingTimeInterval(delay)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileID, relativePath, operation, timestamp, retryCount, priority, nextAttemptAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileID = try container.decode(String.self, forKey: .fileID)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        operation = try container.decode(SyncOperation.self, forKey: .operation)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        priority = try container.decodeIfPresent(SyncPriority.self, forKey: .priority) ?? .normal
        nextAttemptAt = try container.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
    }
}

enum SyncModePreset: Int {
    case balanced = 0
    case lowImpact = 1

    var maxConcurrentRequests: Int {
        switch self {
            case .balanced: return 3
            case .lowImpact: return 2
        }
    }

    var debounceInterval: TimeInterval {
        switch self {
            case .balanced: return 0.5
            case .lowImpact: return 1.2
        }
    }

    var maxBatchWait: TimeInterval {
        switch self {
            case .balanced: return 3.0
            case .lowImpact: return 6.0
        }
    }
}

/// File state for synchronization comparison
struct SyncFileState: Equatable, Hashable {
    let fileID: String
    let relativePath: String
    let contentType: FileStorageContentType
    let modifiedAt: Date
    let size: Int64
    let downloadStatus: DownloadStatus?  // macOS: iCloud download status, iOS: nil

    enum Location {
        case local
        case iCloud
    }

    /// iCloud download status (macOS only)
    enum DownloadStatus: Equatable, Hashable {
        case notDownloaded  // File not downloaded (placeholder only)
        case downloaded     // File downloaded but cloud has update
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
        downloadStatus: DownloadStatus? = nil
    ) {
        self.fileID = fileID
        self.relativePath = relativePath
        self.contentType = contentType
        self.modifiedAt = modifiedAt
        self.size = size
        self.downloadStatus = downloadStatus
    }
}
