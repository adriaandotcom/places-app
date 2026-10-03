import SwiftUI

struct CompanionSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var companions = model.companions
        Form {
            Section {
                Text("Your iPhone is the main recorder. Companion locations help fill gaps; they don’t replace your corrections or recent iPhone observations.")
            }
            Section {
                Toggle("Receive Watch locations", isOn: Binding(get: { companions.watchEnabled }, set: { companions.setWatchEnabled($0) }))
                Text("Open Places on your Watch once to allow location access. It rests when your iPhone is available or the Watch has Wi-Fi. watchOS controls background opportunities.")
                    .font(.caption).foregroundStyle(.secondary)
                if companions.watchEnabled {
                    Text("Saved locations arrive automatically, including when you open Places on your iPhone. There’s no need to send them from your Watch.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let date = companions.lastWatchReceived {
                        LabeledContent("Last received from Watch") { Text(date, style: .relative) }
                    }
                }
            } header: { Label("Apple Watch", systemImage: "applewatch") }
            Section {
                Toggle("Receive Mac locations through iCloud", isOn: Binding(get: { companions.macEnabled }, set: { value in
                    Task { await companions.setMacEnabled(value) }
                })).disabled(companions.configuring)
                Text("Use the same iCloud account and enable iCloud Keychain on both devices. Then enable collection in the Mac menu bar. Only locations collected while you actively use the Mac are sent.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("Mac", systemImage: "laptopcomputer") } footer: {
                Text("Records are encrypted on the Mac before upload to private CloudKit. Keys are shared through end-to-end encrypted iCloud Keychain. Delivered records are removed from the inbox after this iPhone saves them. This does not back up or sync your full history.")
            }
            Section {
                Text(companions.status).font(.callout)
                if let date = companions.lastReceived { LabeledContent("Last received") { Text(date, style: .relative) } }
                if companions.macEnabled { Button("Check for Mac observations") { Task { await companions.sync() } }.disabled(companions.syncing) }
            }
        }.navigationTitle("Companions")
    }
}
