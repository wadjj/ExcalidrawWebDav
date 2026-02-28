import Foundation

struct WebDAVPreferences: Sendable {
    var endpoint: URL?
    var basePath: String

    static let `default` = WebDAVPreferences(endpoint: nil, basePath: "/")
}

actor WebDAVPreferenceStore {
    private enum Keys {
        static let endpoint = "webdav.endpoint"
        static let basePath = "webdav.basePath"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WebDAVPreferences {
        let endpoint = defaults.url(forKey: Keys.endpoint)
        let basePath = defaults.string(forKey: Keys.basePath) ?? "/"
        return WebDAVPreferences(endpoint: endpoint, basePath: basePath)
    }

    func save(_ preferences: WebDAVPreferences) {
        defaults.set(preferences.endpoint, forKey: Keys.endpoint)
        defaults.set(preferences.basePath, forKey: Keys.basePath)
    }
}
