import Foundation

actor WebDAVBackend: CloudBackend {
    private let client: WebDAVClient
    private var conflictQueue: [WebDAVConflictRecord] = []

    private let bootstrapDirectoriesList = [
        "Files",
        "CollaborationFiles",
        "MediaItems",
        "Checkpoints"
    ]

    init(client: WebDAVClient = WebDAVClient()) {
        self.client = client
    }

    func bootstrapDirectories() async throws {
        for directory in bootstrapDirectoriesList {
            try await client.mkcol(relativePath: directory)
        }
    }

    func listMetadata(at relativePath: String) async throws -> [RemoteFileMetadata] {
        try await client.propfind(relativePath: relativePath, depth: 1)
    }

    func fetchMetadata(for relativePath: String) async throws -> RemoteFileMetadata? {
        let metadata = try await client.propfind(relativePath: relativePath, depth: 0)
        return metadata.first(where: { !$0.relativePath.isEmpty }) ?? metadata.first
    }

    func download(relativePath: String) async throws -> Data {
        try await client.get(relativePath: relativePath).data
    }

    func upload(_ data: Data, relativePath: String, overwrite: Bool) async throws -> RemoteFileMetadata {
        if !overwrite {
            return try await client.put(data, relativePath: relativePath, ifMatch: "*")
        }

        let remoteMetadata = try await fetchMetadata(for: relativePath)

        do {
            return try await client.put(
                data,
                relativePath: relativePath,
                ifMatch: remoteMetadata?.etag,
                ifUnmodifiedSince: remoteMetadata?.lastModified
            )
        } catch WebDAVClientError.unexpectedStatus(let statusCode) where statusCode == 412 || statusCode == 409 {
            let conflict = CloudConflict(
                relativePath: relativePath,
                localETag: nil,
                remoteETag: remoteMetadata?.etag,
                localLastModified: nil,
                remoteLastModified: remoteMetadata?.lastModified
            )
            enqueueConflict(conflict)
            throw conflict
        }
    }

    func delete(relativePath: String) async throws {
        try await client.delete(relativePath: relativePath)
    }

    func dequeueConflicts() -> [WebDAVConflictRecord] {
        defer { conflictQueue.removeAll() }
        return conflictQueue
    }

    private func enqueueConflict(_ conflict: CloudConflict) {
        let action: WebDAVConflictResolutionAction = conflict.remoteETag != nil ? .enqueueMergeSafe : .enqueueDownload
        conflictQueue.append(
            WebDAVConflictRecord(
                relativePath: conflict.relativePath,
                localETag: conflict.localETag,
                remoteETag: conflict.remoteETag,
                localLastModified: conflict.localLastModified,
                remoteLastModified: conflict.remoteLastModified,
                action: action,
                recordedAt: Date()
            )
        )
    }
}
