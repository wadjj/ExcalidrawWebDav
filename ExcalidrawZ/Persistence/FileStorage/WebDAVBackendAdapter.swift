import Foundation
import Combine
import Logging

/// Placeholder WebDAV backend. iCloud remains the default provider.
actor WebDAVBackendAdapter: CloudStorageBackend {
    private let logger = Logger(label: "WebDAVBackendAdapter")
    private let statusSubject = CurrentValueSubject<ICloudAvailabilityStatus, Never>(.unavailable)

    nonisolated let provider: CloudStorageProvider = .webDAV

    func checkAvailability() async -> ICloudAvailabilityStatus {
        statusSubject.value
    }

    func startMonitoringAvailability() async {
        statusSubject.send(.unavailable)
    }

    func getAvailabilityPublisher() async -> AnyPublisher<ICloudAvailabilityStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    func loadContent(relativePath: String) async throws -> Data {
        logger.warning("WebDAV load not implemented: \(relativePath)")
        throw FileStorageError.storageUnavailable
    }

    func deleteContent(relativePath: String) async throws {
        logger.warning("WebDAV delete not implemented: \(relativePath)")
        throw FileStorageError.storageUnavailable
    }

    func upload(
        fileID: String,
        localData: Data,
        localUpdatedAt: Date?,
        type: FileStorageContentType
    ) async throws -> String {
        logger.warning("WebDAV upload not implemented for \(type): \(fileID)")
        throw FileStorageError.storageUnavailable
    }

    func getFileURL(relativePath: String) async throws -> URL {
        throw FileStorageError.storageUnavailable
    }

    func getContainerURL() async -> URL? {
        nil
    }
}
