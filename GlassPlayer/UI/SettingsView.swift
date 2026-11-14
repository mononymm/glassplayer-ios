import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var plex: PlexStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hdr") private var hdr = true
    @AppStorage("upNextSeconds") private var upNextSeconds = 0
    @AppStorage("upNextAuto") private var upNextAuto = true
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
                        let c = ConnectionInfo(uri: s.uri)
                        HStack {
                            Text("Connection")
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(c.kind).foregroundStyle(.white)
                                Text(c.host).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .contextMenu {
                            Button { UIPasteboard.general.string = s.uri } label: { Label("Copy full address", systemImage: "doc.on.doc") }
                        }
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
                    Toggle("Play next episode automatically", isOn: $upNextAuto)
                    Picker("Show the card", selection: $upNextSeconds) {
                        Text("At the credits").tag(0)
                        Text("10 seconds before the end").tag(10)
                        Text("20 seconds before the end").tag(20)
                        Text("30 seconds before the end").tag(30)
                        Text("45 seconds before the end").tag(45)
                        Text("1 minute before the end").tag(60)
                        Text("90 seconds before the end").tag(90)
                        Text("2 minutes before the end").tag(120)
                    }
                    .disabled(!upNextAuto)
                } header: {
                    Text("Up next")
                } footer: {
                    Text("\"At the credits\" uses Plex's credits marker when the episode has one, otherwise the last 20 seconds. Tap Play now on the card to skip ahead, or Cancel to stay.")
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


/// Turns "https://192-168-1-20.abc123.plex.direct:32400" into "Home network" + "192.168.1.20:32400".
struct ConnectionInfo {
    let kind: String
    let host: String

    init(uri: String) {
        let comps = URLComponents(string: uri)
        let rawHost = comps?.host ?? uri
        let port = comps?.port.map { ":\($0)" } ?? ""
        var ip = rawHost
        if rawHost.hasSuffix(".plex.direct"), let first = rawHost.split(separator: ".").first {
            ip = first.replacingOccurrences(of: "-", with: ".")
        }
        host = ip + port
        let isPrivate = ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("127.")
            || (ip.hasPrefix("172.") && (Int(ip.split(separator: ".").dropFirst().first ?? "") ?? 0) / 16 == 1)
        if rawHost.contains("relay") || uri.contains("relay") { kind = "Plex relay (slower)" }
        else if isPrivate { kind = "Home network" }
        else { kind = "Remote" }
    }
}
