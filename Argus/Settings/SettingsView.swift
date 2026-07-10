import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gear") }
            appearance
                .tabItem { Label("Appearance", systemImage: "textformat") }
            terminal
                .tabItem { Label("Terminal", systemImage: "terminal") }
            filesAndChanges
                .tabItem { Label("Files & Changes", systemImage: "doc.text") }
            browser
                .tabItem { Label("Browser", systemImage: "globe") }
        }
        .frame(width: 560, height: 430)
    }

    private var general: some View {
        Form {
            Toggle("Restore previous session", isOn: $settings.restorePreviousSession)

            Picker("Default Right-sidebar View", selection: $settings.defaultRightSidebarView) {
                ForEach(AppSettings.RightSidebarView.allCases) { view in
                    Text(view.title).tag(view)
                }
            }

            LabeledContent("Default Standalone Workspace Directory") {
                HStack {
                    Text(settings.defaultStandaloneWorkspaceDirectory)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.defaultStandaloneWorkspaceDirectory)
                        .accessibilityValue(settings.defaultStandaloneWorkspaceDirectory)
                    Button("Choose...") { chooseStandaloneWorkspaceDirectory() }
                    Button("Reset to Home") { settings.resetStandaloneWorkspaceDirectoryToHome() }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var appearance: some View {
        Form {
            Stepper(
                "Interface text size: \(Int(settings.interfaceTextSize))",
                value: $settings.interfaceTextSize,
                in: 10...14
            )
            Stepper(
                "Document text size: \(Int(settings.documentTextSize))",
                value: $settings.documentTextSize,
                in: 10...24
            )
            Picker("Interface density", selection: $settings.interfaceDensity) {
                ForEach(AppSettings.InterfaceDensity.allCases) { density in
                    Text(density.title).tag(density)
                }
            }
            Section("Application Shell") {
                LabeledContent("Shell background") { Text("Black (fixed)") }
                LabeledContent("Terminal appearance") { Text("Ghostty configuration") }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var terminal: some View {
        Form {
            Toggle("Audible bell", isOn: $settings.audibleBell)

            Section("Ghostty Configuration") {
                LabeledContent("Configuration path") {
                    Text(GhosttyConfig.standardConfigurationURL.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(GhosttyConfig.standardConfigurationURL.path)
                        .accessibilityValue(GhosttyConfig.standardConfigurationURL.path)
                }
                HStack {
                    Button("Reveal in Finder") { revealGhosttyConfiguration() }
                    Button("Open Configuration") { openGhosttyConfiguration() }
                    Button("Reload Configuration") {
                        GhosttyApp.shared.reloadConfiguration(source: "settings")
                    }
                }
                Text("Font, theme, and background remain configured by Ghostty.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var filesAndChanges: some View {
        Form {
            Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
            Toggle("Wrap source lines", isOn: $settings.wrapSourceLines)
            Toggle("Open Markdown in preview", isOn: $settings.openMarkdownInPreview)
            Toggle("Open SVG in preview", isOn: $settings.openSVGInPreview)
            Picker("Default diff style", selection: $settings.defaultDiffStyle) {
                ForEach(AppSettings.DiffStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            Picker("Default diff overflow", selection: $settings.defaultDiffOverflow) {
                ForEach(AppSettings.DiffOverflow.allCases) { overflow in
                    Text(overflow.title).tag(overflow)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var browser: some View {
        Form {
            Section("Defaults for New Browser Tabs") {
                TextField("Homepage", text: $settings.homepage, prompt: Text("about:blank"))
                Text("Leave empty to open about:blank.")
                    .foregroundStyle(.secondary)
                Picker("Search provider", selection: $settings.searchProvider) {
                    ForEach(BrowserPanelConfiguration.SearchProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                Stepper(
                    "Default zoom: \(Int(settings.defaultZoom * 100))%",
                    value: $settings.defaultZoom,
                    in: 0.5...2,
                    step: 0.1
                )
                Toggle("Enable Web Inspector", isOn: $settings.webInspectorEnabled)
                Picker("Data store", selection: $settings.browserDataStore) {
                    ForEach(BrowserPanelConfiguration.DataStore.allCases) { dataStore in
                        Text(dataStore.title).tag(dataStore)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseStandaloneWorkspaceDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.defaultStandaloneWorkspaceDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.defaultStandaloneWorkspaceDirectory = url.standardizedFileURL.path
    }

    private func revealGhosttyConfiguration() {
        let url = GhosttyConfig.standardConfigurationURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openGhosttyConfiguration() {
        let url = GhosttyConfig.standardConfigurationURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.open(url)
    }
}
