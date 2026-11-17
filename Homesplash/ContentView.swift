import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var sync: HealthSync
    @AppStorage(Settings.serverKey) private var server = ""
    @AppStorage(Settings.moduleKey) private var module = ""
    @State private var token = Settings.token ?? ""
    @State private var authError: String?
    @State private var authorized = UserDefaults.standard.bool(forKey: "healthAuthorized")

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    statusRow
                    Button {
                        Task { await sync.sync() }
                    } label: {
                        HStack {
                            Text(sync.syncing ? "Syncing…" : "Sync now")
                            Spacer()
                            if sync.syncing { ProgressView() }
                        }
                    }
                    .disabled(sync.syncing || !Settings.isConfigured || !authorized)
                } header: { Text("Status") }

                Section {
                    TextField("http://192.168.1.20:8080", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Push token (HEALTH_PUSH_TOKEN)", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: token) { _, value in Settings.token = value }
                    TextField("Module (default apple_health)", text: $module)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: { Text("Homesplash server") } footer: {
                    Text(Settings.pushURL.map { "Pushes to \($0.absoluteString)" } ?? "Enter the address of the PC running Homesplash.")
                }

                Section {
                    Button(authorized ? "Health access granted — review" : "Allow Health access") {
                        Task {
                            do {
                                try await sync.requestAuthorization()
                                authorized = true
                                UserDefaults.standard.set(true, forKey: "healthAuthorized")
                                authError = nil
                            } catch {
                                authError = error.localizedDescription
                            }
                        }
                    }
                    if let authError { Text(authError).foregroundStyle(.red).font(.footnote) }
                } header: { Text("Apple Health") } footer: {
                    Text("Reads steps, active energy, heart rate, resting heart rate, HRV, blood oxygen and sleep. Nothing is written to Health. Syncs when you open the app and in the background (iOS decides how often; Health data is unreadable while the phone is locked).")
                }

                if !sync.lastCounts.isEmpty {
                    Section {
                        ForEach(sync.lastCounts.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            LabeledContent(key.replacingOccurrences(of: "_", with: " "), value: "\(value)")
                        }
                    } header: { Text("Last payload") }
                }
            }
            .navigationTitle("Homesplash")
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sync.lastResult).font(.headline)
            if let last = sync.lastSync {
                Text("Last successful sync \(last.formatted(.relative(presentation: .named)))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
