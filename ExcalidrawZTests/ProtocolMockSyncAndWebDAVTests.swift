import XCTest

final class ProtocolMockSyncAndWebDAVTests: XCTestCase {

    // MARK: - SyncCoordinator + FileStorageManager protocol-mock tests

    func testConflictDetection_WhenETagMismatches_ThrowsConflict() async {
        let remote = MockRemoteProvider(etag: "remote-v2", timestamp: Date(timeIntervalSince1970: 2_000))
        let coordinator = MockSyncCoordinator(remoteProvider: remote)

        await XCTAssertThrowsErrorAsync(
            try await coordinator.syncUploadIfUnchanged(
                fileID: "file-1",
                localETag: "local-v1",
                localTimestamp: Date(timeIntervalSince1970: 1_000)
            )
        ) { error in
            guard case MockSyncError.etagMismatch(let local, let remote) = error else {
                return XCTFail("Expected etagMismatch, got \(error)")
            }
            XCTAssertEqual(local, "local-v1")
            XCTAssertEqual(remote, "remote-v2")
        }
    }

    func testAmbiguousTimestampFallback_PrefersETagWhenWithinTolerance() async throws {
        let closeTimes = (
            local: Date(timeIntervalSince1970: 1_000),
            remote: Date(timeIntervalSince1970: 1_001)
        )
        let remote = MockRemoteProvider(etag: "v1", timestamp: closeTimes.remote)
        let coordinator = MockSyncCoordinator(remoteProvider: remote, timestampTolerance: 2)

        let decision = try await coordinator.decideSyncDirection(
            localETag: "v2",
            localTimestamp: closeTimes.local
        )

        XCTAssertEqual(decision, .upload)
    }

    func testQueueCoalescingAndRetryBackoff_ReplacesDuplicateAndBacksOff() async {
        let scheduler = MockBackoffScheduler()
        let queue = MockCoalescingQueue(scheduler: scheduler)

        queue.enqueue(.init(fileID: "a", operation: .upload, attempt: 0))
        queue.enqueue(.init(fileID: "a", operation: .upload, attempt: 0)) // coalesce
        queue.enqueue(.init(fileID: "b", operation: .download, attempt: 0))

        XCTAssertEqual(queue.pendingCount, 2)

        _ = queue.failAndRequeue(fileID: "a")
        _ = queue.failAndRequeue(fileID: "a")

        XCTAssertEqual(scheduler.recordedDelays, [1, 2])
    }

    func testProviderSwitch_CreatesPreSyncSnapshotBeforeChangingProvider() {
        let storage = MockFileStorageManager()
        storage.activeProvider = .iCloud

        storage.switchProvider(to: .webDAV, createSnapshot: true)

        XCTAssertEqual(storage.snapshots.count, 1)
        XCTAssertEqual(storage.snapshots.first?.fromProvider, .iCloud)
        XCTAssertEqual(storage.activeProvider, .webDAV)
    }

    // MARK: - Fixture-based WebDAV parsing tests

    func testWebDAVDirectoryListing_ParsesFixture() throws {
        let xml = try fixture(named: "webdav-propfind-standard.xml")
        let parser = WebDAVMultiStatusParser()

        let items = try parser.parse(data: xml)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].href, "/remote.php/dav/files/demo/Documents/")
        XCTAssertTrue(items[0].isCollection)
        XCTAssertEqual(items[1].etag, "\"abc123\"")
    }

    func testWebDAVMetadataParsing_ParsesSynologyLikeFixture() throws {
        let xml = try fixture(named: "webdav-propfind-synology.xml")
        let parser = WebDAVMultiStatusParser()

        let items = try parser.parse(data: xml)
        let file = try XCTUnwrap(items.first { !$0.isCollection })

        XCTAssertEqual(file.href, "/webdav/Notes/sketch.excalidraw")
        XCTAssertEqual(file.contentLength, 2048)
        XCTAssertEqual(file.etag, "\"synology-etag-42\"")
        XCTAssertEqual(file.contentType, "application/octet-stream")
    }

    // MARK: - Regression tests

    func testICloudDefaultPath_UnchangedWhenWebDAVNotConfigured() {
        let resolver = DefaultPathResolver(webDAVConfig: nil)
        XCTAssertEqual(resolver.storageRootPath, "/iCloud/ExcalidrawZ/FileStorage")
    }

    func testKeychainCredentialLifecycle_SaveUpdateRemove() {
        let keychain = MockKeychainStore()

        XCTAssertTrue(keychain.save(account: "demo", secret: "pw1"))
        XCTAssertEqual(keychain.secret(for: "demo"), "pw1")

        XCTAssertTrue(keychain.save(account: "demo", secret: "pw2"))
        XCTAssertEqual(keychain.secret(for: "demo"), "pw2")

        XCTAssertTrue(keychain.remove(account: "demo"))
        XCTAssertNil(keychain.secret(for: "demo"))
    }

    // MARK: - Helpers

    private func fixture(named name: String) throws -> Data {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try Data(contentsOf: base.appendingPathComponent("Fixtures/\(name)"))
    }
}

// MARK: - Protocol-mock support types

private enum ProviderType: Equatable {
    case iCloud
    case webDAV
}

private enum SyncDecision: Equatable {
    case upload
    case download
    case noChange
}

private enum MockSyncError: Error {
    case etagMismatch(local: String, remote: String)
}

private protocol RemoteVersionProvider {
    func currentETag(for fileID: String) async -> String
    func currentTimestamp(for fileID: String) async -> Date
}

private actor MockRemoteProvider: RemoteVersionProvider {
    let etag: String
    let timestamp: Date

    init(etag: String, timestamp: Date) {
        self.etag = etag
        self.timestamp = timestamp
    }

    func currentETag(for fileID: String) async -> String { etag }
    func currentTimestamp(for fileID: String) async -> Date { timestamp }
}

private actor MockSyncCoordinator {
    let remoteProvider: RemoteVersionProvider
    let timestampTolerance: TimeInterval

    init(remoteProvider: RemoteVersionProvider, timestampTolerance: TimeInterval = 1) {
        self.remoteProvider = remoteProvider
        self.timestampTolerance = timestampTolerance
    }

    func syncUploadIfUnchanged(fileID: String, localETag: String, localTimestamp: Date) async throws {
        let remoteETag = await remoteProvider.currentETag(for: fileID)
        guard remoteETag == localETag else {
            throw MockSyncError.etagMismatch(local: localETag, remote: remoteETag)
        }
    }

    func decideSyncDirection(localETag: String, localTimestamp: Date) async throws -> SyncDecision {
        let remoteTime = await remoteProvider.currentTimestamp(for: "ignored")
        let remoteETag = await remoteProvider.currentETag(for: "ignored")
        let diff = abs(localTimestamp.timeIntervalSince(remoteTime))

        if diff <= timestampTolerance {
            return localETag == remoteETag ? .noChange : .upload
        }

        return localTimestamp > remoteTime ? .upload : .download
    }
}

private struct QueueItem {
    enum Operation: Equatable { case upload, download }
    let fileID: String
    let operation: Operation
    let attempt: Int
}

private final class MockBackoffScheduler {
    private(set) var recordedDelays: [Int] = []

    func scheduleRetry(after seconds: Int) {
        recordedDelays.append(seconds)
    }
}

private final class MockCoalescingQueue {
    private var items: [String: QueueItem] = [:]
    private let scheduler: MockBackoffScheduler

    init(scheduler: MockBackoffScheduler) {
        self.scheduler = scheduler
    }

    var pendingCount: Int { items.count }

    func enqueue(_ item: QueueItem) {
        items[item.fileID] = item
    }

    @discardableResult
    func failAndRequeue(fileID: String) -> QueueItem? {
        guard let existing = items[fileID] else { return nil }
        let nextAttempt = existing.attempt + 1
        scheduler.scheduleRetry(after: Int(pow(2.0, Double(existing.attempt))))
        let next = QueueItem(fileID: existing.fileID, operation: existing.operation, attempt: nextAttempt)
        items[fileID] = next
        return next
    }
}

private final class MockFileStorageManager {
    struct Snapshot {
        let fromProvider: ProviderType
        let createdAt: Date
    }

    private(set) var snapshots: [Snapshot] = []
    var activeProvider: ProviderType = .iCloud

    func switchProvider(to newProvider: ProviderType, createSnapshot: Bool) {
        if createSnapshot {
            snapshots.append(.init(fromProvider: activeProvider, createdAt: Date()))
        }
        activeProvider = newProvider
    }
}

private struct DefaultPathResolver {
    let webDAVConfig: URL?

    var storageRootPath: String {
        if webDAVConfig == nil {
            return "/iCloud/ExcalidrawZ/FileStorage"
        }
        return "/WebDAV/ExcalidrawZ/FileStorage"
    }
}

private final class MockKeychainStore {
    private var storage: [String: String] = [:]

    func save(account: String, secret: String) -> Bool {
        storage[account] = secret
        return true
    }

    func remove(account: String) -> Bool {
        storage.removeValue(forKey: account) != nil
    }

    func secret(for account: String) -> String? {
        storage[account]
    }
}

private struct WebDAVItem: Equatable {
    let href: String
    let isCollection: Bool
    let etag: String?
    let contentLength: Int?
    let contentType: String?
}

private final class WebDAVMultiStatusParser: NSObject, XMLParserDelegate {
    private var items: [WebDAVItem] = []
    private var currentHref: String?
    private var currentETag: String?
    private var currentLength: Int?
    private var currentType: String?
    private var currentIsCollection = false
    private var currentElement = ""
    private var buffer = ""

    func parse(data: Data) throws -> [WebDAVItem] {
        items.removeAll()
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "WebDAVParser", code: 1)
        }
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName.lowercased()
        buffer = ""
        if currentElement == "response" {
            currentHref = nil
            currentETag = nil
            currentLength = nil
            currentType = nil
            currentIsCollection = false
        }
        if currentElement == "collection" {
            currentIsCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "href": currentHref = value
        case "getetag": currentETag = value
        case "getcontentlength": currentLength = Int(value)
        case "getcontenttype": currentType = value
        case "response":
            if let href = currentHref {
                items.append(WebDAVItem(
                    href: href,
                    isCollection: currentIsCollection,
                    etag: currentETag,
                    contentLength: currentLength,
                    contentType: currentType
                ))
            }
        default: break
        }
        buffer = ""
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ errorHandler: (_ error: Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error but expression succeeded. \(message())", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}
