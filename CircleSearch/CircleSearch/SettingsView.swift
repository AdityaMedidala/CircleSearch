import SwiftUI
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
            APITab()
                .tabItem { Label("API", systemImage: "key") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 400)
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

    @AppStorage("selectedModel") private var selectedModel = AnthropicClient.defaultModel
    @State private var apiKey   = ""
    @State private var status   = ""

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
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            let rawKey = KeychainManager.load()
            NSLog("CircleSearch: APITab.onAppear — KeychainManager.load() = %@",
                  rawKey == nil ? "nil" : "loaded \(rawKey!.count) chars")
            NSLog("CircleSearch: APITab.onAppear — bundle ID = %@",
                  Bundle.main.bundleIdentifier ?? "(nil)")
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
