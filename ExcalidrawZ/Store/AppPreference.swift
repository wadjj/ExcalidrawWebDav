//
//  AppPreference.swift
//  ExcalidrawZ
//
//  Created by Dove Zachary on 2024/10/8.
//

import SwiftUI
import WebKit
import Combine
import Logging
import Security

import ChocofordUI
import UniformTypeIdentifiers

final class AppPreference: ObservableObject {
    enum SyncProvider: String, CaseIterable, Identifiable {
        case iCloud
        case webdav

        var id: String { rawValue }

        var title: String {
            switch self {
                case .iCloud:
                    return "iCloud"
                case .webdav:
                    return "WebDAV"
            }
        }
    }

    enum SidebarMode: Hashable, Sendable {
        case all
        case filesOnly
    }
    enum LayoutStyle: Int, Sendable, RadioGroupCase, Hashable {
        case sidebar
        case floatingBar
        
        var id: Int { rawValue }
        
        func imageName(_ name: String) -> String {
            switch self {
                case .sidebar:
                    "Layout-\(name)-Modern"
                case .floatingBar:
                    "Layout-\(name)-Floating"
            }
        }
        
        var availability: Bool {
            switch self {
                case .sidebar:
                    if #available(macOS 13.0, *) {
                        return true
                    } else {
                        return false
                    }
                case .floatingBar:
                    return true
            }
        }
    }
    // Layout
    @Published var sidebarMode: SidebarMode = .all
    @Published var sidebarLayout: LayoutStyle = {
        if #available(macOS 13.0, *) {
            return .sidebar
        } else {
            return .floatingBar
        }
    }()
    
    @Published var inspectorLayout: LayoutStyle = {
        if #available(macOS 14.0, *) {
            return .sidebar
        } else {
            return .floatingBar
        }
    }()
    // Appearence
    enum Appearance: String, RadioGroupCase {
        case light
        case dark
        case auto
        
        var text: String {
            switch self {
                case .light:
                    return String(localizable: .settingsAppearanceColorScemeLight)
                case .dark:
                    return String(localizable: .settingsAppearanceColorScemeDark)
                case .auto:
                    return String(localizable: .settingsAppearanceColorScemeAuto)
            }
        }
        
        var id: String {
            self.text
        }
        
        var colorScheme: ColorScheme? {
            switch self {
                case .light:
                    return .light
                case .dark:
                    return .dark
                case .auto:
                    return nil
            }
        }
    }
    @AppStorage("appearance") var appearance: Appearance = .auto
    @AppStorage("excalidrawAppearance") var excalidrawAppearance: Appearance = .auto
    
    var appearanceBinding: Binding<ColorScheme?> {
        Binding {
            self.appearance.colorScheme
        } set: { val in
            switch val {
                case .light:
                    self.appearance = .light
                case .dark:
                    self.appearance = .dark
                case .none:
                    self.appearance = .auto
                case .some(_):
                    self.appearance = .light
            }
        }
    }
    /// Invert the inverted image in dark mode.
    @AppStorage("autoInvertImage") var autoInvertImage = true
    @AppStorage("autoInvertImageSettings") private var autoInvertImageSettings: String = ""
    
    var antiInvertImageSettings: AntiInvertImageSettings {
        get {
            do {
                guard let data = autoInvertImageSettings.data(using: .utf8) else {
                    return AntiInvertImageSettings()
                }
                return try JSONDecoder().decode(AntiInvertImageSettings.self, from: data)
            } catch {
                return AntiInvertImageSettings()
            }
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                if let string = String(data: data, encoding: .utf8) {
                    self.autoInvertImageSettings = string
                }
            } catch {

            }
        }
    }

    // User Drawing Settings
    @AppStorage("useCustomDrawingSettings") var useCustomDrawingSettings = false
    @AppStorage("customDrawingSettingsData") private var customDrawingSettingsData: Data = Data()

    // Sync provider
    @AppStorage("SyncProvider") var syncProvider: SyncProvider = .iCloud {
        didSet {
            syncCloudSyncPreference()
        }
    }
    @AppStorage("WebDAVServerURL") var webdavServerURL: String = ""
    @AppStorage("WebDAVBasePath") var webdavBasePath: String = ""
    @AppStorage("WebDAVUsername") var webdavUsername: String = ""
    @AppStorage("WebDAVHasStoredCredential") var webdavHasStoredCredential: Bool = false
    @AppStorage("WebDAVLastConnected") var webdavLastConnected: Bool = false
    @Published var webdavPassword: String = ""
    @Published private(set) var isICloudAvailable: Bool = AppPreference.computeICloudAvailability()

    private var iCloudAvailabilityObserver: NSObjectProtocol?

    var customDrawingSettings: UserDrawingSettings {
        get {
            do {
                let settings = try JSONDecoder().decode(UserDrawingSettings.self, from: customDrawingSettingsData)
                return settings
            } catch {
                print("Decode customDrawingSettings error", error)
                return UserDrawingSettings()
            }
            
        }
        set {
            customDrawingSettingsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    init() {
        webdavHasStoredCredential = loadWebDAVPasswordFromKeychain() != nil
        syncCloudSyncPreference()

        iCloudAvailabilityObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshICloudAvailability()
        }
        refreshICloudAvailability()
    }

    func storeWebDAVPasswordInKeychain() {
        guard !webdavPassword.isEmpty else {
            removeWebDAVPasswordFromKeychain()
            return
        }

        let account = webdavUsername.isEmpty ? "default" : webdavUsername
        let encodedPassword = Data(webdavPassword.utf8)
        let query = webDAVPasswordQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: encodedPassword]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData as String] = encodedPassword
            let insertStatus = SecItemAdd(insertQuery as CFDictionary, nil)
            webdavHasStoredCredential = insertStatus == errSecSuccess
            return
        }

        webdavHasStoredCredential = status == errSecSuccess
    }

    func loadWebDAVPasswordFromKeychain() -> String? {
        let account = webdavUsername.isEmpty ? "default" : webdavUsername
        var query = webDAVPasswordQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    func removeWebDAVPasswordFromKeychain() {
        let account = webdavUsername.isEmpty ? "default" : webdavUsername
        _ = SecItemDelete(webDAVPasswordQuery(account: account) as CFDictionary)
        webdavHasStoredCredential = false
    }

    private func syncCloudSyncPreference() {
        UserDefaults.standard.set(syncProvider != .iCloud, forKey: "DisableCloudSync")
    }

    private func webDAVPasswordQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.chocoford.excalidraw.webdav",
            kSecAttrAccount as String: account
        ]
    }

    deinit {
        if let iCloudAvailabilityObserver {
            NotificationCenter.default.removeObserver(iCloudAvailabilityObserver)
        }
    }

    func refreshICloudAvailability() {
        isICloudAvailable = Self.computeICloudAvailability()
    }

    private static func computeICloudAvailability() -> Bool {
        if FileManager.default.ubiquityIdentityToken == nil {
            return false
        }
        return FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
    }
}


struct AntiInvertImageSettings: Codable, Hashable {
    var png: Bool = true
    var svg: Bool = false
}
