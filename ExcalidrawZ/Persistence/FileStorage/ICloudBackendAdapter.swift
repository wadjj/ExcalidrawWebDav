import Foundation
import Combine

/// CloudStorageBackend adapter preserving existing iCloudDriveFileManager behavior.
actor ICloudBackendAdapter: CloudStorageBackend {
    private let manager: iCloudDriveFileManager

    nonisolated let provider: CloudStorageProvider = .iCloud

    init(manager: iCloudDriveFileManager = iCloudDriveFileManager()) {
        self.manager = manager
    }

    func checkAvailability() async -> ICloudAvailabilityStatus {
        await manager.checkICloudAvailability()
    }

    func startMonitoringAvailability() async {
        await manager.startMonitoringICloudAvailability()
    }

    func getAvailabilityPublisher() async -> AnyPublisher<ICloudAvailabilityStatus, Never> {
        await manager.iCloudStatusPublisher
    }

    func loadContent(relativePath: String) async throws -> Data {
        try await manager.loadContent(relativePath: relativePath)
    }

    func deleteContent(relativePath: String) async throws {
        try await manager.deleteContent(relativePath: relativePath)
    }

    func upload(
        fileID: String,
        localData: Data,
        localUpdatedAt: Date?,
        type: FileStorageContentType
    ) async throws -> String {
        try await manager.uploadToICloud(
            fileID: fileID,
            localData: localData,
            localUpdatedAt: localUpdatedAt,
            type: type
        )
    }

    func getFileURL(relativePath: String) async throws -> URL {
        try await manager.getFileURL(relativePath: relativePath)
    }

    func getContainerURL() async -> URL? {
        await manager.containerURL
    }

    func refreshMetadataIfNeeded(fileURL: URL) async {
        #if os(iOS)
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
            try? await Task.sleep(nanoseconds: 100_000_000)
        } catch {
            // Best-effort metadata refresh.
        }
        #endif
    }

    func triggerContainerDownloadIfNeeded() async {
        guard let containerURL = await manager.containerURL else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: containerURL)
    }

    func getCurrentStatus() async -> ICloudAvailabilityStatus {
        await manager.getCurrentStatus()
    }
}
