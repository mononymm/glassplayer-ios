import SwiftUI
import UniformTypeIdentifiers

struct SignInView: View {
    @EnvironmentObject var plex: PlexStore
    var play: (PlayRequest) -> Void
    @State private var importing = false

    var body: some View {
        ZStack {
            Backdrop()

            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 104, height: 104)
                    .glassEffect(.regular.tint(Theme.accent.opacity(0.8)), in: .rect(cornerRadius: 28))

                VStack(spacing: 6) {
                    Text("Glass").font(.system(size: 34, weight: .bold))
                    Text("Your Plex library, played by mpv.")
                        .foregroundStyle(Theme.secondaryText)
                }

                if let pin = plex.pin {
                    VStack(spacing: 14) {
                        Text("Go to plex.tv/link and enter")
                            .foregroundStyle(Theme.secondaryText)
                        Text(pin.code)
                            .font(.system(size: 44, weight: .heavy, design: .monospaced))
                            .kerning(8)
                            .textSelection(.enabled)
                        HStack(spacing: 12) {
                            Button {
                                UIPasteboard.general.string = pin.code
                                if let u = URL(string: "https://plex.tv/link") { UIApplication.shared.open(u) }
                            } label: {
                                Label("Copy code & open plex.tv/link", systemImage: "safari")
                                    .padding(.horizontal, 6)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.accent)
                        }
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Waiting for Plex…").font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                        Button("Cancel") { plex.cancelSignIn() }
                            .buttonStyle(.glass)
                    }
                    .padding(26)
                    .glassEffect(.regular, in: .rect(cornerRadius: 30))
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                } else {
                    VStack(spacing: 12) {
                        Button { plex.beginSignIn() } label: {
                            Text("Sign in with Plex")
                                .font(.headline)
                                .frame(maxWidth: 280)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)

                        Button { importing = true } label: {
                            Label("Play a file instead", systemImage: "folder")
                                .frame(maxWidth: 280)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                    }
                }

                if let err = plex.signInError {
                    Text(err).font(.footnote).foregroundStyle(Theme.accent)
                }
                Spacer()
            }
            .padding(24)
            .foregroundStyle(.white)
            .animation(.spring(duration: 0.35), value: plex.pin?.id)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .audiovisualContent, .data]) { result in
            if case .success(let url) = result { play(LocalFiles.request(for: url)) }
        }
    }
}

/// Dark backdrop with a faint red glow, so the glass has something to refract.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.accent.opacity(0.28), .clear], center: .topLeading, startRadius: 10, endRadius: 520)
            RadialGradient(colors: [Color.blue.opacity(0.12), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}

enum LocalFiles {
    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "wmv", "flv", "mpg", "mpeg", "ogv", "3gp"]

    static func request(for url: URL) -> PlayRequest {
        _ = url.startAccessingSecurityScopedResource()
        return PlayRequest(url: url, title: url.deletingPathExtension().lastPathComponent, subtitle: nil,
                           start: LocalPositions.get(url.lastPathComponent), localKey: url.lastPathComponent)
    }

    /// Videos copied into the app's folder (Files app → On My iPhone → Glass).
    static func documents() -> [URL] {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let list = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }
        return list.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
