import SwiftUI
import KeyboardShortcuts
import ServiceManagement

// MARK: - SettingsView

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
            ProvidersTab()
                .tabItem { Label("Providers", systemImage: "key") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 500)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Keyboard Shortcut") {
                KeyboardShortcuts.Recorder("Capture shortcut:", name: .triggerCapture)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            NSLog("SMAppService error: %@", error.localizedDescription)
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Providers

private struct ProvidersTab: View {

    @AppStorage("defaultProvider") private var defaultProvider = "anthropic"

    // Per-provider model selections — intentionally separate AppStorage keys.
    @AppStorage("selectedModel_anthropic") private var anthropicModel = AnthropicProvider.defaultModel
    @AppStorage("selectedModel_openai")    private var openAIModel    = OpenAIProvider.defaultModel
    @AppStorage("selectedModel_google")    private var googleModel     = GoogleProvider.defaultModel

    // Transient UI state — not persisted.
    @State private var expanded:       [ProviderType: Bool]   = [:]
    @State private var keyFields:      [ProviderType: String] = [:]   // text field value; starts empty
    @State private var savedKeyExists: [ProviderType: Bool]   = [:]   // mirrors Keychain state
    @State private var statuses:       [ProviderType: String] = [:]   // brief feedback messages

    var body: some View {
        Form {
            // Top segmented picker — at-a-glance default provider selector.
            Section("Default Provider") {
                Picker("Default provider", selection: $defaultProvider) {
                    ForEach(ProviderType.allCases, id: \.rawValue) { p in
                        Text(shortLabel(p)).tag(p.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // One card per provider, identical in structure, data-driven.
            ForEach(ProviderType.allCases, id: \.rawValue) { p in
                Section {
                    DisclosureGroup(isExpanded: expandedBinding(for: p)) {
                        sectionBody(for: p)
                    } label: {
                        sectionLabel(for: p)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            setupInitialState()
        }
        .onChange(of: defaultProvider) { _, newValue in
            // Expand the newly-activated section so the user sees it became active.
            if let p = ProviderType(rawValue: newValue) {
                withAnimation(.easeInOut(duration: 0.2)) { expanded[p] = true }
            }
        }
    }

    // MARK: Section label — shown in the DisclosureGroup header row

    @ViewBuilder
    private func sectionLabel(for p: ProviderType) -> some View {
        HStack(spacing: 6) {
            Text(p.displayName)
                .font(.callout.weight(.medium))
            Spacer()
            if defaultProvider == p.rawValue {
                Text("active")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(.tint)
                    .clipShape(Capsule())
            } else if savedKeyExists[p] == true {
                Text("key saved")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Section body — all settings for one provider

    @ViewBuilder
    private func sectionBody(for p: ProviderType) -> some View {
        // API key input — field intentionally starts empty; use Clear to remove existing key.
        SecureField(keyPlaceholder(p), text: keyFieldBinding(for: p))

        HStack(spacing: 6) {
            Button("Save") { saveKey(for: p) }
                .disabled(
                    (keyFields[p] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                )
            Button("Clear") { clearKey(for: p) }
                .disabled(savedKeyExists[p] != true)
            Spacer()
            if let status = statuses[p], !status.isEmpty {
                Text(status)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .animation(.easeInOut, value: status)
            }
        }

        Link("Get an API key →", destination: p.consoleURL)
            .font(.caption)

        // Model picker — each provider has its own AppStorage key.
        Picker("Model", selection: modelBinding(for: p)) {
            ForEach(p.models, id: \.id) { m in
                Text(m.label).tag(m.id)
            }
        }
        .pickerStyle(.menu)

        // Default provider toggle — mirrors the top segmented picker.
        if defaultProvider == p.rawValue {
            Label("Currently active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        } else {
            Button("Set as default") {
                defaultProvider = p.rawValue
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: Setup

    private func setupInitialState() {
        for p in ProviderType.allCases {
            savedKeyExists[p] = KeychainManager.load(for: p) != nil
        }

        // Smart expansion: expand the default section only if any keys exist.
        // If no keys are saved, expand all three to encourage first-time setup.
        let anyKeysSaved = ProviderType.allCases.contains { savedKeyExists[$0] == true }
        let activeType   = ProviderType(rawValue: defaultProvider) ?? .anthropic

        for p in ProviderType.allCases {
            expanded[p] = anyKeysSaved ? (p == activeType) : true
        }
    }

    // MARK: Actions

    private func saveKey(for p: ProviderType) {
        let trimmed = (keyFields[p] ?? "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainManager.save(trimmed, for: p)
            savedKeyExists[p] = true
            withAnimation { statuses[p] = "Saved." }
            // Clear the field and fade the status after 2 s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                keyFields[p] = ""
                withAnimation { statuses[p] = "" }
            }
        } catch {
            statuses[p] = error.localizedDescription
        }
    }

    private func clearKey(for p: ProviderType) {
        do {
            try KeychainManager.delete(for: p)
            savedKeyExists[p] = false
            keyFields[p]      = ""
            withAnimation { statuses[p] = "Cleared." }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { statuses[p] = "" }
            }
        } catch {
            statuses[p] = error.localizedDescription
        }
    }

    // MARK: Bindings + helpers

    private func expandedBinding(for p: ProviderType) -> Binding<Bool> {
        Binding(
            get: { expanded[p] ?? false },
            set: { expanded[p] = $0 }
        )
    }

    private func keyFieldBinding(for p: ProviderType) -> Binding<String> {
        Binding(
            get: { keyFields[p] ?? "" },
            set: { keyFields[p] = $0 }
        )
    }

    /// Returns the correct `@AppStorage` binding for each provider's model selection.
    /// Must be a switch rather than a dictionary because `@AppStorage` bindings are
    /// statically declared property wrappers and cannot be constructed dynamically.
    private func modelBinding(for p: ProviderType) -> Binding<String> {
        switch p {
        case .anthropic: return $anthropicModel
        case .openai:    return $openAIModel
        case .google:    return $googleModel
        }
    }

    /// Short labels for the segmented picker — full display names are used in section headers.
    private func shortLabel(_ p: ProviderType) -> String {
        switch p {
        case .anthropic: return "Claude"
        case .openai:    return "OpenAI"
        case .google:    return "Gemini"
        }
    }

    /// Placeholder text hinting at the expected key format for each provider.
    private func keyPlaceholder(_ p: ProviderType) -> String {
        switch p {
        case .anthropic: return "sk-ant-…"
        case .openai:    return "sk-…"
        case .google:    return "AIza…"
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("CircleSearch")
                .font(.title2.bold())
            Text("Version \(version)")
                .foregroundStyle(.secondary)
            Text("Open source OCR + AI assistant for any screen region.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 280)
            Link("View on GitHub →",
                 destination: URL(string: "https://github.com/adityamedidala/CircleSearch")!)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
