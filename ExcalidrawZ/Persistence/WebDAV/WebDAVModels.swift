import Foundation

struct RemoteFileMetadata: Equatable, Hashable, Sendable {
    let etag: String?
    let lastModified: Date?
    let contentLength: Int64?
    let relativePath: String
}

enum WebDAVConflictResolutionAction: Sendable {
    case enqueueDownload
    case enqueueMergeSafe
}

struct WebDAVConflictRecord: Sendable {
    let relativePath: String
    let localETag: String?
    let remoteETag: String?
    let localLastModified: Date?
    let remoteLastModified: Date?
    let action: WebDAVConflictResolutionAction
    let recordedAt: Date
}
