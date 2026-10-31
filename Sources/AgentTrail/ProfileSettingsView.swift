import AppKit
import SwiftUI
import AgentTrailCore

/// Edits Agent Trail's own profile configuration. Assistant files are only read.
struct ProfileSettingsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftSources: [AgentSource]
    @State private var selectedID: String?
    @State private var draftInterval: Double
    @State private var validationMessage: String?
    private let onClose: (() -> Void)?

    init(store: AppStore, onClose: (() -> Void)? = nil) {
        self.store = store
        self.onClose = onClose
        _draftSources = State(initialValue: store.sources)
        _selectedID = State(initialValue: store.sources.first?.id)
        _draftInterval = State(initialValue: store.refreshInterval)
    }

    private var selectedIndex: Int? {
        draftSources.firstIndex { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                profileList
                Divider()
                profileEditor
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Profiles")
                    .font(.system(size: 15, weight: .semibold))
                Text("Connect the Claude, Codex, and Grok profiles you work with.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.demoMode {
                Text("DEMO")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.orange.opacity(0.10), in: Capsule())
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PROFILES")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(draftSources.enumerated()), id: \.element.id) { index, source in
                        Button {
                            selectedID = source.id
                            validationMessage = nil
                        } label: {
                            HStack(spacing: 9) {
                                Circle().fill(profileColor(index))
                                    .frame(width: 7, height: 7)
                                Text(source.name.isEmpty ? "Untitled profile" : source.name)
                                    .font(.system(size: 12, weight: selectedID == source.id ? .medium : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(selectedID == source.id ? Color.blue.opacity(0.10) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit \(source.name) profile")
                        .accessibilityAddTraits(selectedID == source.id ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 8)
            }
            HStack(spacing: 0) {
                Button(action: addProfile) { Image(systemName: "plus").frame(width: 26, height: 24) }
                    .help("Add a profile")
                    .accessibilityLabel("Add a profile")
                Divider().frame(height: 12)
                Button(action: removeProfile) { Image(systemName: "minus").frame(width: 26, height: 24) }
                    .disabled(selectedIndex == nil || draftSources.count <= 1)
                    .help("Remove this profile from Agent Trail")
                    .accessibilityLabel("Remove selected profile")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(10)
            .disabled(store.demoMode)
        }
        .frame(width: 182)
        .background(.primary.opacity(0.018))
    }

    private var profileEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                if let index = selectedIndex {
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Assistant", symbol: "sparkles")
                        Picker("Assistant", selection: assistantBinding) {
                            ForEach(AssistantKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Assistant")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Profile name", symbol: "person.crop.circle")
                        TextField("e.g. Claude · Work", text: sourceBinding(\.name))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Profile name")
                    }

                    folderField(configTitle(draftSources[index].assistant), symbol: "folder",
                                placeholder: draftSources[index].assistant.defaultHome(home: "~"),
                                value: sourceBinding(\.configDirectory), field: .config)

                    if draftSources[index].assistant == .claude {
                        VStack(alignment: .leading, spacing: 6) {
                            folderField("Desktop user-data folder", symbol: "macwindow", placeholder: "Default Claude desktop profile",
                                        value: userDataBinding, field: .userData)
                            Text("Leave blank only for the default Claude profile. For custom config folders, enter the matching --user-data-dir folder.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("\(draftSources[index].assistant.displayName) history is read from this home. Shell commands are not counted as file edits, and there is no live status yet.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().padding(.vertical, 1)

                    HStack {
                        Label("Refresh activity", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Refresh activity", selection: $draftInterval) {
                            ForEach(Array(Set([15.0, 30.0, 60.0, draftInterval])).sorted(), id: \.self) { interval in
                                Text("Every \(Int(interval)) seconds").tag(interval)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .controlSize(.small)
                    }
                }
            }
            .disabled(store.demoMode)
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Could not save profiles: \(validationMessage)")
            }
            HStack(spacing: 12) {
                Text(store.demoMode ? "Demo profiles are a preview. Relaunch without --demo to connect yours."
                     : "Reads local records. Saving never restarts an assistant.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Save profiles", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.demoMode)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func fieldLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func folderField(_ title: String, symbol: String, placeholder: String,
                             value: Binding<String>, field: FolderField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(title, symbol: symbol)
            HStack(spacing: 7) {
                TextField(placeholder, text: value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .accessibilityLabel(title)
                Button { chooseFolder(field) } label: { Image(systemName: "folder") }
                    .help("Choose \(title.lowercased())")
                    .accessibilityLabel("Choose \(title.lowercased())")
            }
        }
    }

    private func sourceBinding(_ keyPath: WritableKeyPath<AgentSource, String>) -> Binding<String> {
        Binding {
            guard let index = selectedIndex else { return "" }
            return draftSources[index][keyPath: keyPath]
        } set: { value in
            guard let index = selectedIndex else { return }
            draftSources[index][keyPath: keyPath] = value
            validationMessage = nil
        }
    }

    private var assistantBinding: Binding<AssistantKind> {
        Binding {
            guard let index = selectedIndex else { return .claude }
            return draftSources[index].assistant
        } set: { kind in
            setAssistant(kind)
        }
    }

    private func configTitle(_ assistant: AssistantKind) -> String {
        switch assistant {
        case .claude: return "Claude config folder"
        case .codex: return "Codex home"
        case .grok: return "Grok home"
        }
    }

    private func setAssistant(_ kind: AssistantKind) {
        guard let index = selectedIndex, draftSources[index].assistant != kind else { return }
        let previous = draftSources[index].assistant
        draftSources[index].assistant = kind
        if kind == .claude {
            draftSources[index].bundleIdentifier = "com.anthropic.claudefordesktop"
        } else {
            draftSources[index].userDataDirectory = nil
            draftSources[index].bundleIdentifier = ""
        }
        let previousHome = previous.defaultHome(home: "~")
        if draftSources[index].configDirectory.isEmpty || draftSources[index].configDirectory == previousHome {
            draftSources[index].configDirectory = kind.defaultHome(home: "~")
        }
        validationMessage = nil
    }

    private var userDataBinding: Binding<String> {
        Binding {
            guard let index = selectedIndex else { return "" }
            return draftSources[index].userDataDirectory ?? ""
        } set: { value in
            guard let index = selectedIndex else { return }
            draftSources[index].userDataDirectory = value.isEmpty ? nil : value
            validationMessage = nil
        }
    }

    private enum FolderField { case config, userData }

    private func chooseFolder(_ field: FolderField) {
        guard let index = selectedIndex else { return }
        let sourceID = draftSources[index].id
        let currentPath = field == .config ? draftSources[index].configDirectory
            : (draftSources[index].userDataDirectory ?? "")
        let panel = NSOpenPanel()
        let assistant = draftSources[index].assistant.displayName
        panel.title = field == .config ? "Choose \(assistant) home folder" : "Choose desktop user-data folder"
        panel.prompt = "Choose folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        if !currentPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: NSString(string: currentPath).expandingTildeInPath)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let selected = draftSources.firstIndex(where: { $0.id == sourceID }) else { return }
            if field == .config {
                draftSources[selected].configDirectory = url.path
            } else {
                draftSources[selected].userDataDirectory = url.path
            }
            validationMessage = nil
        }
    }

    private func addProfile() {
        var number = draftSources.count + 1
        while draftSources.contains(where: { $0.name == "Claude \(number)" }) { number += 1 }
        let profile = AgentSource(id: "claude-\(UUID().uuidString.lowercased())", name: "Claude \(number)",
                                  configDirectory: "")
        draftSources.append(profile)
        selectedID = profile.id
        validationMessage = nil
    }

    private func removeProfile() {
        guard let index = selectedIndex, draftSources.count > 1 else { return }
        draftSources.remove(at: index)
        selectedID = draftSources[min(index, draftSources.count - 1)].id
        validationMessage = nil
    }

    private func save() {
        let normalized = draftSources.map { source in
            var source = source
            source.name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            source.configDirectory = source.configDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            let userData = source.userDataDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            source.userDataDirectory = userData.isEmpty ? nil : userData
            return source
        }
        do {
            try store.saveProfiles(normalized, refreshInterval: draftInterval)
            close()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func profileColor(_ index: Int) -> Color {
        [.blue, .orange, .purple, .teal, .pink][index % 5]
    }
}
