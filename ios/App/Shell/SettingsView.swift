import SwiftUI
import FTApp

/// Identifiers (masked by default; shown for one session after a confirmation), storage, privacy and about.
struct SettingsView: View {
    @Bindable var app: AppModel
    @State private var confirmReveal = false
    @State private var confirmDelete = false
    @State private var storageBytes: Int64 = 0

    var body: some View {
        Form {
            Section {
                Toggle("Show identifiers", isOn: revealBinding)
                    .accessibilityIdentifier("revealIdentifiers")
            } header: {
                Text("Identifiers")
            } footer: {
                Text(app.revealIdentifiers
                     ? "Shown until FieldTap is closed. They are included when you copy or share a message."
                     : "Masked (recommended). IMSI, IMEI, phone number, IP addresses, tracking area and cell identity show as <masked> on every screen and in everything you copy or share.")
            }

            Section("Storage") {
                LabeledContent("Captures", value: "\(app.captures.count)")
                LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
                Button("Delete all captures", role: .destructive) { confirmDelete = true }
                    .disabled(app.captures.isEmpty)
            }

            Section("Privacy") {
                Label("No network. Nothing leaves this iPhone unless you share it.", systemImage: "lock.shield")
                Label("FieldTap keeps only the modem trace from a sysdiagnose, on this iPhone.", systemImage: "internaldrive")
            }

            Section("About") {
                LabeledContent("Version", value: version)
                LabeledContent("Call-flow contract", value: "v1")
                LabeledContent("LTE RRC records", value: "v30, layout E")
                LabeledContent("NR RRC records", value: "v26, layout E")
                NavigationLink("Licences and notices") { NoticesView() }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Show identifiers?", isPresented: $confirmReveal, titleVisibility: .visible) {
            Button("Show for this session") { app.revealIdentifiers = true }
            Button("Keep masked", role: .cancel) {}
        } message: {
            Text("Your IMSI, IMEI, phone number, IP addresses and cell identity become visible, and are included when you copy or share. They are masked again the next time FieldTap opens.")
        }
        .confirmationDialog("Delete all captures?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(app.captures.count) captures", role: .destructive) {
                do {
                    try app.deleteAll()
                } catch {
                    app.lastError = "Could not delete: \(error.localizedDescription)"
                }
                storageBytes = app.storageBytes()
            }
        } message: {
            Text("Frees \(ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file)). This cannot be undone.")
        }
        .task(id: app.captures.count) { storageBytes = app.storageBytes() }
    }

    /// Turning reveal on asks first; turning it off does not.
    private var revealBinding: Binding<Bool> {
        Binding(get: { app.revealIdentifiers }, set: { on in
            if on { confirmReveal = true } else { app.revealIdentifiers = false }
        })
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

/// Licences and attributions.
struct NoticesView: View {
    var body: some View {
        List {
            Section("Record layouts") {
                Text("Some PHY record layout facts were cross-checked against MobileInsight (Apache License 2.0, mobileinsight.net). No MobileInsight code is included.")
            }
            Section("Standards") {
                Text("Band and frequency tables, TBS tables and message names follow 3GPP TS 36.101, 36.213, 38.104, 38.214, 24.301 and 24.501.")
            }
            Section("Apple's logging profile") {
                Text("Modem logging uses Apple's Baseband logging profile, which you install from Apple yourself. FieldTap does not include, host or change it.")
            }
        }
        .navigationTitle("Licences and notices")
    }
}
