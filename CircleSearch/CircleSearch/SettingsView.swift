import SwiftUI
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
            APITab()
                .tabItem { Label("Anthropic", systemImage: "key") }
            OpenAITestTab()
                .tabItem { Label("OpenAI", systemImage: "sparkles") }
            GoogleTestTab()
                .tabItem { Label("Google", systemImage: "globe") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 420)
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

// MARK: - API

private struct APITab: View {

    // Model options shown in the picker.
    private let models: [(id: String, label: String)] = [
        ("claude-sonnet-4-6",        "claude-sonnet-4-6 (default)"),
        ("claude-haiku-4-5-20251001", "claude-haiku-4-5-20251001 (faster / cheaper)"),
        ("claude-opus-4-7",           "claude-opus-4-7 (most capable, slower)"),
    ]

    @AppStorage("defaultProvider") private var defaultProvider = "anthropic"
    @AppStorage("selectedModel") private var selectedModel = AnthropicProvider.defaultModel
    @State private var apiKey   = ""
    @State private var status   = ""

    private var isDefault: Bool { defaultProvider == ProviderType.anthropic.rawValue }

    var body: some View {
        Form {
            Section("Anthropic API Key") {
                SecureField("sk-ant-…", text: $apiKey)
                HStack {
                    Button("Save")  { saveKey() }
                    Button("Clear") { clearKey() }
                    Spacer()
                    if !status.isEmpty {
                        Text(status)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                Link("Get an API key →",
                     destination: URL(string: "https://console.anthropic.com/")!)
                    .font(.caption)
            }
            Section("Model") {
                Picker("Model", selection: $selectedModel) {
                    ForEach(models, id: \.id) { m in
                        Text(m.label).tag(m.id)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Active Provider") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default provider")
                        Text(isDefault ? "Currently: Anthropic" : "Currently: \(defaultProvider)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isDefault {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else {
                        Button("Restore as default") {
                            defaultProvider = ProviderType.anthropic.rawValue
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            let rawKey = KeychainManager.load()
            NSLog("CircleSearch: APITab.onAppear — KeychainManager.load() = %@",
                  rawKey == nil ? "nil" : "loaded \(rawKey!.count) chars")
            apiKey = rawKey ?? ""
        }
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        do {
            if trimmed.isEmpty {
                try KeychainManager.delete()
                status = "Cleared."
            } else {
                try KeychainManager.save(trimmed)
                status = "Saved."
            }
        } catch {
            status = error.localizedDescription
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { status = "" }
    }

    private func clearKey() {
        apiKey = ""
        saveKey()
    }
}

// MARK: - OpenAI (Phase 2 temporary tab — replaced by Providers tab in Phase 4)

private struct OpenAITestTab: View {

    @AppStorage("defaultProvider") private var defaultProvider = "anthropic"
    @AppStorage("selectedModel_openai") private var selectedModel = OpenAIProvider.defaultModel

    @State private var apiKey = ""
    @State private var status = ""

    private var isDefault: Bool { defaultProvider == ProviderType.openai.rawValue }

    var body: some View {
        Form {
            Section("OpenAI API Key") {
                SecureField("sk-…", text: $apiKey)
                HStack {
                    Button("Save")  { saveKey() }
                    Button("Clear") { clearKey() }
                    Spacer()
                    if !status.isEmpty {
                        Text(status)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                Link("Get an API key →", destination: OpenAIProvider.consoleURL)
                    .font(.caption)
            }

            Section("Model") {
                Picker("Model", selection: $selectedModel) {
                    ForEach(OpenAIProvider.models, id: \.id) { m in
                        Text(m.label).tag(m.id)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Active Provider") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default provider")
                        Text(isDefault ? "Currently: OpenAI" : "Currently: \(defaultProvider)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isDefault {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else {
                        Button("Set as default") {
                            defaultProvider = ProviderType.openai.rawValue
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                if !isDefault {
                    Button("Restore Anthropic as default") {
                        defaultProvider = ProviderType.anthropic.rawValue
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            apiKey = KeychainManager.load(for: .openai) ?? ""
        }
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        do {
            if trimmed.isEmpty {
                try KeychainManager.delete(for: .openai)
                status = "Cleared."
            } else {
                try KeychainManager.save(trimmed, for: .openai)
                status = "Saved."
            }
        } catch {
            status = error.localizedDescription
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { status = "" }
    }

    private func clearKey() {
        apiKey = ""
        saveKey()
    }
}

// MARK: - Google (Phase 3 temporary tab — replaced by Providers tab in Phase 4)

private struct GoogleTestTab: View {

    @AppStorage("defaultProvider") private var defaultProvider = "anthropic"
    @AppStorage("selectedModel_google") private var selectedModel = GoogleProvider.defaultModel

    @State private var apiKey = ""
    @State private var status = ""

    private var isDefault: Bool { defaultProvider == ProviderType.google.rawValue }

    var body: some View {
        Form {
            Section("Google AI API Key") {
                SecureField("AIza…", text: $apiKey)
                HStack {
                    Button("Save")  { saveKey() }
                    Button("Clear") { clearKey() }
                    Spacer()
                    if !status.isEmpty {
                        Text(status)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                Link("Get an API key →", destination: GoogleProvider.consoleURL)
                    .font(.caption)
            }

            Section("Model") {
                Picker("Model", selection: $selectedModel) {
                    ForEach(GoogleProvider.models, id: \.id) { m in
                        Text(m.label).tag(m.id)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Active Provider") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default provider")
                        Text(isDefault ? "Currently: Google Gemini" : "Currently: \(defaultProvider)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isDefault {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else {
                        Button("Set as default") {
                            defaultProvider = ProviderType.google.rawValue
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                if !isDefault {
                    Button("Restore Anthropic as default") {
                        defaultProvider = ProviderType.anthropic.rawValue
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            apiKey = KeychainManager.load(for: .google) ?? ""
        }
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        do {
            if trimmed.isEmpty {
                try KeychainManager.delete(for: .google)
                status = "Cleared."
            } else {
                try KeychainManager.save(trimmed, for: .google)
                status = "Saved."
            }
        } catch {
            status = error.localizedDescription
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { status = "" }
    }

    private func clearKey() {
        apiKey = ""
        saveKey()
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
