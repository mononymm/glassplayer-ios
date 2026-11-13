import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var plex: PlexStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hdr") private var hdr = true
    @State private var connecting: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Plex server") {
                    if plex.resources.isEmpty, let s = plex.server {
                        HStack {
                            Text(s.name)
                            Spacer()
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                    ForEach(plex.resources, id: \.clientIdentifier) { r in
                        Button {
                            connecting = r.clientIdentifier
                            Task {
                                await plex.pickServer(r)
                                connecting = nil
                            }
                        } label: {
                            HStack {
                                Text(r.name).foregroundStyle(.white)
                                Spacer()
                                if connecting == r.clientIdentifier { ProgressView() }
                                else if plex.server?.id == r.clientIdentifier {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                    if let s = plex.server {
                        LabeledContent("Address", value: s.uri)
                            .font(.footnote)
                    }
                }

                Section {
                    Toggle("HDR output", isOn: $hdr)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Shows HDR10 / HLG video in HDR on screens that support it. Applies to the next video you open.")
                }

                Section {
                    Button("Sign out of Plex", role: .destructive) {
                        plex.signOut()
                        dismiss()
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    LabeledContent("Engine", value: "mpv via MPVKit")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                if plex.resources.isEmpty, let t = plex.token {
                    plex.resources = (try? await plex.api.servers(token: t)) ?? []
                }
            }
        }
    }
}
