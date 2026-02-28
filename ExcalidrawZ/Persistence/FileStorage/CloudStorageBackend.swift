import Foundation
import Combine

/// Selected cloud storage provider for file synchronization.
enum CloudStorageProvider: String {
    case iCloud
    case webDAV
}

/// Backend abstraction used by SyncCoordinator and FileStorageManager.
protocol CloudStorageBackend: Sendable {
    var provider: CloudStorageProvider { get }

    func checkAvailability() async -> ICloudAvailabilityStatus
    func startMonitoringAvailability() async
    func getAvailabilityPublisher() async -> AnyPublisher<ICloudAvailabilityStatus, Never>

    func loadContent(relativePath: String) async throws -> Data
    func deleteContent(relativePath: String) async throws
    func upload(
        fileID: String,
        localData: Data,
        localUpdatedAt: Date?,
        type: FileStorageContentType
    ) async throws -> String

    func getFileURL(relativePath: String) async throws -> URL
    func getContainerURL() async -> URL?

    /// Optional metadata refresh hook used before timestamp comparison.
    func refreshMetadataIfNeeded(fileURL: URL) async

    /// Optional monitor hook used when a diff scan sees a high missing ratio.
    func triggerContainerDownloadIfNeeded() async

    func getCurrentStatus() async -> ICloudAvailabilityStatus
}

extension CloudStorageBackend {
    func refreshMetadataIfNeeded(fileURL: URL) async {}

    func triggerContainerDownloadIfNeeded() async {}

    func getCurrentStatus() async -> ICloudAvailabilityStatus {
        await checkAvailability()
    }
}
