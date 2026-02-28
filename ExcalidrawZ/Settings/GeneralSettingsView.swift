//
//  GeneralSettingsView.swift
//  ExcalidrawZ
//
//  Created by Dove Zachary on 2023/5/12.
//

import SwiftUI
import ChocofordUI
#if os(macOS) && !APP_STORE
import Sparkle
#endif

enum FolderStructureStyle: Int {
    case disclosureGroup
    case tree
}

private struct FolderChildren: Identifiable, Hashable {
    var id = UUID()
}

struct GeneralSettingsView: View {
    @Environment(\.colorScheme) var colorScheme
#if os(macOS) && !APP_STORE
    @EnvironmentObject var updateChecker: UpdateChecker
#endif
    @EnvironmentObject var appPreference: AppPreference

    @AppStorage("DisableCloudSync") var isICloudDisabled: Bool = false

    @AppStorage("FolderStructureStyle") var folderStructStyle: FolderStructureStyle = .disclosureGroup

    @State private var isDisclosureGroupUnspportedAlertPresented = false
    @State private var webdavConnectionStatus: String?
    @State private var isTestingWebDAVConnection = false

    struct DisclosureGroupUnspportedError: LocalizedError {
        var errorDescription: String? {
            "Disclosure Group Style is unavailable below macOS 13.0."
        }
    }

    var body: some View {
        if #available(macOS 14.0, *) {
            Form {
                content()
            }
            .formStyle(.grouped)
        } else {
            ScrollView {
                VStack {
                    content()
                }
                .padding()
            }
        }
    }

    @MainActor @ViewBuilder
    private func content() -> some View {
        Section {
            settingCellView(.localizable(.settingsAppAppearanceName)) {
                HStack(spacing: 16) {
                    RadioGroup(selected: $appPreference.appearance) { option, isOn in
                        RadioButton(isOn: isOn) {
                            Text(option.text)
                        }
                    }
                }
            }
            settingCellView(.localizable(.settingsExcalidrawAppearanceName)) {
                HStack(spacing: 16) {
                    RadioGroup(selected: $appPreference.excalidrawAppearance) { option, isOn in
                        RadioButton(isOn: isOn) {
                            Text(option.text)
                        }
                    }
                }
            }
        } header: {
            if #available(macOS 14.0, *) {
                Text(.localizable(.settingsAppAppearanceName))
            } else {
                Text(.localizable(.settingsAppAppearanceName))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        Section {
            Picker("Sync Provider", selection: $appPreference.syncProvider) {
                ForEach(AppPreference.SyncProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }

            if appPreference.syncProvider == .webdav {
                TextField("Server URL", text: $appPreference.webdavServerURL)
                    .textInputAutocapitalization(.never)
#if os(iOS)
                    .autocorrectionDisabled(true)
#endif
                TextField("Base Path", text: $appPreference.webdavBasePath)
                TextField("Username", text: $appPreference.webdavUsername)
                SecureField("Password", text: $appPreference.webdavPassword)

                HStack {
                    Button(appPreference.webdavHasStoredCredential ? "Update Password in Keychain" : "Save Password to Keychain") {
                        appPreference.webdavHasStoredCredential = !appPreference.webdavPassword.isEmpty
                    }
                    .disabled(appPreference.webdavPassword.isEmpty)

                    Spacer()

                    AsyncButton {
                        await testWebDAVConnection()
                    } label: {
                        if isTestingWebDAVConnection {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTestingWebDAVConnection || appPreference.webdavServerURL.isEmpty)
                }

                if let webdavConnectionStatus {
                    Text(webdavConnectionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                StatusBadge(title: "iCloud unavailable", isVisible: !appPreference.isICloudAvailable)
                StatusBadge(title: "WebDAV connected", isVisible: appPreference.syncProvider == .webdav && appPreference.webdavLastConnected)
                StatusBadge(title: "offline queue active", isVisible: appPreference.syncProvider == .webdav && !appPreference.webdavLastConnected)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("iCloud remains the default provider. Switch to WebDAV only if you need it.")
        }

        // Folder structure UI
        Section {
            HStack {
                Text(.localizable(.settingsFolderStructureStyleTitle))
                Spacer()
                Picker(.localizable(.settingsFolderStructureStyleTitle), selection: $folderStructStyle) {
                    Text(.localizable(.settingsFolderStructureStyleDisclosureGroup)).tag(FolderStructureStyle.disclosureGroup)
                    Text(.localizable(.settingsFolderStructureStyleTreeStructure)).tag(FolderStructureStyle.tree)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: folderStructStyle) { newValue in
                    if #available(macOS 13.0, *) { } else {
                        if newValue == .disclosureGroup {
                            isDisclosureGroupUnspportedAlertPresented.toggle()
                            folderStructStyle = .tree
                        }
                    }
                }
                .alert(
                    isPresented: $isDisclosureGroupUnspportedAlertPresented,
                    error: DisclosureGroupUnspportedError()
                ) {

                }
            }
        } footer: {
            HStack {
                VStack(spacing: 10) {
                    Text(.localizable(.settingsFolderStructureDisclosureGroupStyleTitle)).font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemSymbol: .chevronDown).font(.footnote)
                                Text(.localizable(.generalFolderName))
                            }

                            VStack(spacing: 4) {
                                Text(.localizable(.generalSubfolderName))
                                Text(.localizable(.generalSubfolderName))
                            }
                            .padding(.leading, 24)
                        }

                        HStack(spacing: 4) {
                            Image(systemSymbol: .chevronDown).font(.footnote).opacity(0)
                            Text(.localizable(.generalFolderName))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 160)

                Divider()

                VStack(spacing: 10) {
                    let children: [FolderChildren] = [FolderChildren(), FolderChildren()]
                    let children2: [FolderChildren] = []
                    Text(.localizable(.settingsFolderStructureTreeStructureStyleTitle)).font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        VStack(alignment: .leading, spacing: 0) {
                            TreeStructureView(children: children) {
                                Text(.localizable(.generalFolderName))
                            } childView: { _ in
                                TreeStructureView(children: children2) {
                                    Text(.localizable(.generalSubfolderName))
                                } childView: { _ in

                                }
                            }
                        }
                        TreeStructureView(children: children) {
                            Text(.localizable(.generalFolderName)).padding(.vertical, 4)
                        } childView: { _ in

                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 160)
            }
            .foregroundStyle(.secondary)
        }

#if DEBUG
        Section {
            let containerShape = RoundedRectangle(cornerRadius: 8)
            HStack(alignment: .top, spacing: 20) {
                Text("Sidebar").font(.headline).foregroundStyle(.secondary)
                Spacer()
                RadioGroup(selected: $appPreference.sidebarLayout) { option, isOn in
                    Image(option.imageName("Sidebar"))
                        .resizable()
                        .scaledToFit()
                        .frame(height: 120)
                        .clipShape(containerShape)
                        .padding(2)
                        .overlay {
                            if isOn.wrappedValue {
                                containerShape.stroke(Color.accentColor.opacity(0.5), lineWidth: 4)
                            }
                        }
                        .onTapGesture {
                            isOn.wrappedValue = true
                        }
                }
            }

            HStack(alignment: .top, spacing: 20) {
                Text("Inspector").font(.headline).foregroundStyle(.secondary)
                Spacer()
                RadioGroup(selected: $appPreference.inspectorLayout) { option, isOn in
                    Image(option.imageName("Inspector"))
                        .resizable()
                        .scaledToFit()
                        .frame(height: 120)
                        .clipShape(containerShape)
                        .padding(2)
                        .overlay {
                            if isOn.wrappedValue {
                                containerShape.stroke(Color.accentColor.opacity(0.5), lineWidth: 4)
                            }
                        }
                        .onTapGesture {
                            isOn.wrappedValue = true
                        }
                }
            }
        } header: {
            Text("Layout")
        }
#endif

#if os(macOS) && !APP_STORE
        Section {
            Toggle(.localizable(.settingsUpdatesAutoCheckLabel), isOn: $updateChecker.canCheckForUpdates)
        } header: {
            if #available(macOS 14.0, *) {
                Text(.localizable(.settingsUpdateHeadline))
            } else {
                Text(.localizable(.settingsUpdateHeadline))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            HStack {
                Spacer()
                Button {
                    updateChecker.updater?.checkForUpdates()
                } label: {
                    Text(.localizable(.settingsUpdatesButtonCheck))
                }
            }
        }
#endif // os(macOS) && !APP_STORE

        Section {
            Toggle(
                .localizable(.settingsICloudToggleDisable),
                isOn: Binding {
                    FileManager.default.ubiquityIdentityToken == nil ||
                    isICloudDisabled
                } set: { disabled in
                    isICloudDisabled = disabled
                }
            )
            .modifier(ToggleICloudSyncingModifier())
        } header: {
            Text(localizable: .settingsICloudTitle)
        }

        Section {} footer: {
            AsyncButton {
                try await PersistenceController.shared.refreshIndices()
            } label: {
                Text(localizable: .settingsButtonRefreshSpotlightIndices)
            }
        }
    }

    @MainActor
    private func testWebDAVConnection() async {
        isTestingWebDAVConnection = true
        defer { isTestingWebDAVConnection = false }

        guard let url = URL(string: appPreference.webdavServerURL) else {
            webdavConnectionStatus = "Invalid server URL."
            appPreference.webdavLastConnected = false
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        if !appPreference.webdavUsername.isEmpty || !appPreference.webdavPassword.isEmpty {
            let credential = "\(appPreference.webdavUsername):\(appPreference.webdavPassword)"
            guard let data = credential.data(using: .utf8) else { return }
            request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let isConnected = (200..<500).contains(statusCode)
            appPreference.webdavLastConnected = isConnected
            webdavConnectionStatus = isConnected ? "Connected successfully." : "Connection failed (\(statusCode))."
        } catch {
            appPreference.webdavLastConnected = false
            webdavConnectionStatus = "Connection failed: \(error.localizedDescription)"
        }
    }

    @MainActor @ViewBuilder
    func settingCellView<T: View, V: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder trailing: @escaping () -> T,
        @ViewBuilder content: (() -> V) = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .fontWeight(.medium)
                Spacer()
                trailing()
            }

            content()
        }
    }
}

private struct StatusBadge: View {
    let title: String
    let isVisible: Bool

    var body: some View {
        if isVisible {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial)
                .clipShape(Capsule())
        }
    }
}

#if DEBUG
#Preview {
    GeneralSettingsView()
        .environmentObject(AppPreference())
#if os(macOS) && !APP_STORE
        .environmentObject(UpdateChecker())
#endif
}


#Preview {
    if #available(macOS 13.0, *) {
        Form {

        }
        .formStyle(.grouped)
        .environmentObject(AppPreference())
    }
}
#endif
