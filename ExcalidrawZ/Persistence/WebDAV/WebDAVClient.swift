import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif


enum WebDAVClientError: LocalizedError {
    case missingEndpoint
    case invalidResponse
    case unexpectedStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            return "WebDAV endpoint is not configured"
        case .invalidResponse:
            return "Invalid response received from WebDAV server"
        case .unexpectedStatus(let code):
            return "Unexpected HTTP status code: \(code)"
        }
    }
}

actor WebDAVClient {
    private let session: URLSession
    private let preferencesStore: WebDAVPreferenceStore
    private let credentialStore: WebDAVCredentialStore

    init(
        session: URLSession = .shared,
        preferencesStore: WebDAVPreferenceStore = WebDAVPreferenceStore(),
        credentialStore: WebDAVCredentialStore = WebDAVCredentialStore()
    ) {
        self.session = session
        self.preferencesStore = preferencesStore
        self.credentialStore = credentialStore
    }

    func propfind(relativePath: String, depth: Int = 0) async throws -> [RemoteFileMetadata] {
        let requestURL = try await makeURL(relativePath: relativePath)
        var request = try await makeRequest(url: requestURL, method: "PROPFIND")
        request.setValue("\(depth)", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:">
            <d:prop>
                <d:getetag/>
                <d:getlastmodified/>
                <d:getcontentlength/>
            </d:prop>
        </d:propfind>
        """.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVClientError.invalidResponse
        }
        guard httpResponse.statusCode == 207 else {
            throw WebDAVClientError.unexpectedStatus(httpResponse.statusCode)
        }

        return WebDAVMultistatusParser.parse(data: data, rootURL: requestURL)
    }

    func get(relativePath: String) async throws -> (data: Data, metadata: RemoteFileMetadata?) {
        let requestURL = try await makeURL(relativePath: relativePath)
        let request = try await makeRequest(url: requestURL, method: "GET")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebDAVClientError.unexpectedStatus(httpResponse.statusCode)
        }
        return (data, metadata(from: httpResponse, fallbackPath: relativePath))
    }

    func put(
        _ data: Data,
        relativePath: String,
        ifMatch: String? = nil,
        ifUnmodifiedSince: Date? = nil
    ) async throws -> RemoteFileMetadata {
        let requestURL = try await makeURL(relativePath: relativePath)
        var request = try await makeRequest(url: requestURL, method: "PUT")
        request.httpBody = data
        if let ifMatch {
            request.setValue(ifMatch, forHTTPHeaderField: "If-Match")
        }
        if let ifUnmodifiedSince {
            request.setValue(Self.httpDateFormatter.string(from: ifUnmodifiedSince), forHTTPHeaderField: "If-Unmodified-Since")
        }

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebDAVClientError.unexpectedStatus(httpResponse.statusCode)
        }

        return metadata(from: httpResponse, fallbackPath: relativePath)
    }

    func delete(relativePath: String) async throws {
        let requestURL = try await makeURL(relativePath: relativePath)
        let request = try await makeRequest(url: requestURL, method: "DELETE")
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 404 else {
            throw WebDAVClientError.unexpectedStatus(httpResponse.statusCode)
        }
    }

    func mkcol(relativePath: String) async throws {
        let requestURL = try await makeURL(relativePath: relativePath)
        let request = try await makeRequest(url: requestURL, method: "MKCOL")
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 405 else {
            throw WebDAVClientError.unexpectedStatus(httpResponse.statusCode)
        }
    }

    private func makeURL(relativePath: String) async throws -> URL {
        let preferences = await preferencesStore.load()
        guard let endpoint = preferences.endpoint else {
            throw WebDAVClientError.missingEndpoint
        }

        let normalizedBasePath = preferences.basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedRelativePath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var pathComponents = [String]()
        if !normalizedBasePath.isEmpty {
            pathComponents.append(normalizedBasePath)
        }
        if !normalizedRelativePath.isEmpty {
            pathComponents.append(normalizedRelativePath)
        }

        return pathComponents.reduce(endpoint) { partialURL, path in
            partialURL.appendingPathComponent(path)
        }
    }

    private func makeRequest(url: URL, method: String) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method

        if let credential = try await credentialStore.load() {
            let token = "\(credential.username):\(credential.password)"
            let encoded = Data(token.utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private func metadata(from response: HTTPURLResponse, fallbackPath: String) -> RemoteFileMetadata {
        let etag = response.value(forHTTPHeaderField: "ETag")
        let modifiedHeader = response.value(forHTTPHeaderField: "Last-Modified")
        let lengthHeader = response.value(forHTTPHeaderField: "Content-Length")

        return RemoteFileMetadata(
            etag: etag,
            lastModified: modifiedHeader.flatMap(Self.httpDateFormatter.date(from:)),
            contentLength: lengthHeader.flatMap(Int64.init),
            relativePath: fallbackPath
        )
    }
}

private enum WebDAVMultistatusParser {
    static func parse(data: Data, rootURL: URL) -> [RemoteFileMetadata] {
        guard let xml = String(data: data, encoding: .utf8) else {
            return []
        }

        let responsePattern = "<d:response>([\\s\\S]*?)</d:response>"
        let hrefPattern = "<d:href>(.*?)</d:href>"
        let etagPattern = "<d:getetag>(.*?)</d:getetag>"
        let modifiedPattern = "<d:getlastmodified>(.*?)</d:getlastmodified>"
        let lengthPattern = "<d:getcontentlength>(.*?)</d:getcontentlength>"

        guard let responseRegex = try? NSRegularExpression(pattern: responsePattern) else {
            return []
        }

        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let responseMatches = responseRegex.matches(in: xml, range: nsRange)

        return responseMatches.compactMap { match in
            guard let blockRange = Range(match.range(at: 1), in: xml) else {
                return nil
            }
            let block = String(xml[blockRange])
            let href = firstMatch(in: block, pattern: hrefPattern) ?? ""
            let etag = firstMatch(in: block, pattern: etagPattern)
            let modified = firstMatch(in: block, pattern: modifiedPattern)
            let length = firstMatch(in: block, pattern: lengthPattern)

            return RemoteFileMetadata(
                etag: etag,
                lastModified: modified.flatMap(WebDAVClient.httpDateFormatter.date(from:)),
                contentLength: length.flatMap(Int64.init),
                relativePath: relativePath(for: href, rootURL: rootURL)
            )
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange]).removingPercentEncoding
    }

    private static func relativePath(for href: String, rootURL: URL) -> String {
        guard let hrefURL = URL(string: href, relativeTo: rootURL)?.absoluteURL else {
            return href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let rootPath = rootURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var path = hrefURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !rootPath.isEmpty {
            path = path.replacingOccurrences(of: "^\(NSRegularExpression.escapedPattern(for: rootPath))/?", with: "", options: .regularExpression)
        }
        return path
    }
}
