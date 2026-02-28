import Foundation

struct CloudConflict: Error, Sendable {
    let relativePath: String
    let localETag: String?
    let remoteETag: String?
    let localLastModified: Date?
    let remoteLastModified: Date?
}

protocol CloudBackend: Sendable {
    func bootstrapDirectories() async throws
    func listMetadata(at relativePath: String) async throws -> [RemoteFileMetadata]
    func fetchMetadata(for relativePath: String) async throws -> RemoteFileMetadata?
    func download(relativePath: String) async throws -> Data
    func upload(_ data: Data, relativePath: String, overwrite: Bool) async throws -> RemoteFileMetadata
    func delete(relativePath: String) async throws
}
