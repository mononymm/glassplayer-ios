import Foundation
import SwiftUI

/// App-wide Plex state: sign-in, chosen server, home rows.
@MainActor
final class PlexStore: ObservableObject {
    let api = PlexAPI()

    @Published var token: String? = Keychain.get("plexToken")
    @Published var server: PlexServer? = {
        guard let d = UserDefaults.standard.data(forKey: "plexServer") else { return nil }
        return try? JSONDecoder().decode(PlexServer.self, from: d)
    }()
    @Published var resources: [PlexResource] = []

    @Published var pin: PlexPin?
    @Published var signInError: String?

    @Published var continueWatching: [PlexItem] = []
    @Published var sections: [PlexSection] = []
    @Published var recent: [String: [PlexItem]] = [:]
    @Published var loading = false
    @Published var homeError: String?
    /// Show/movie metadata fetched for logos and backdrops (keyed by ratingKey).
    @Published var shows: [String: PlexItem] = [:]

    private var pinTask: Task<Void, Never>?

    var signedIn: Bool { token != nil }

    // MARK: sign-in

    func beginSignIn() {
        signInError = nil
        pinTask?.cancel()
        pinTask = Task {
            do {
                let p = try await api.createPin()
                self.pin = p
                // Poll for ~10 minutes.
                for _ in 0..<300 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                    let check = try await api.checkPin(p.id)
                    if let t = check.authToken, !t.isEmpty {
                        self.finishSignIn(token: t)
                        return
                    }
                }
                self.pin = nil
                self.signInError = "The code expired. Try again."
            } catch is CancellationError {
            } catch {
                self.signInError = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        pinTask?.cancel()
        pin = nil
    }

    private func finishSignIn(token: String) {
        Keychain.set(token, for: "plexToken")
        self.token = token
        self.pin = nil
        Task { await self.pickServer() }
    }

    func signOut() {
        Keychain.set(nil, for: "plexToken")
        UserDefaults.standard.removeObject(forKey: "plexServer")
        token = nil
        server = nil
        resources = []
        continueWatching = []
        sections = []
        recent = [:]
    }

    // MARK: server

    func pickServer(_ preferred: PlexResource? = nil) async {
        guard let token else { return }
        homeError = nil
        do {
            if resources.isEmpty || preferred == nil {
                resources = try await api.servers(token: token)
            }
            let choice = preferred
                ?? resources.first(where: { $0.clientIdentifier == server?.id })
                ?? resources.first(where: { $0.owned })
                ?? resources.first
            guard let choice else { throw PlexError.noServer }
            let s = try await api.connect(choice, accountToken: token)
            setServer(s)
            await refreshHome()
        } catch {
            homeError = error.localizedDescription
        }
    }

    private func setServer(_ s: PlexServer) {
        server = s
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "plexServer") }
    }

    // MARK: home

    func refreshHome(retry: Bool = true) async {
        guard let server else {
            if signedIn { await pickServer() }
            return
        }
        loading = true
        defer { loading = false }
        do {
            async let cw = api.continueWatching(server)
            async let secs = api.sections(server)
            let (c, s) = try await (cw, secs)
            continueWatching = c
            sections = s
            homeError = nil
            var rec: [String: [PlexItem]] = [:]
            for sec in s {
                rec[sec.key] = (try? await api.recentlyAdded(server, section: sec.key)) ?? []
            }
            recent = rec
        } catch {
            // The saved address may have changed (e.g. away from home): reconnect once.
            homeError = error.localizedDescription
            var res = resources.first(where: { $0.clientIdentifier == server.id })
            if res == nil, let token {
                let list = (try? await api.servers(token: token)) ?? []
                res = list.first(where: { $0.clientIdentifier == server.id })
            }
            if retry, let res, let s = try? await api.connect(res, accountToken: token ?? "") {
                setServer(s)
                homeError = nil
                await refreshHome(retry: false)
            }
        }
    }

    /// Full metadata (with title logo) for the show an item belongs to, fetched once.
    func show(for item: PlexItem) async -> PlexItem? {
        let key = item.showKey
        if let s = shows[key] { return s }
        guard let server, let s = try? await api.metadata(server, key) else { return nil }
        shows[key] = s
        return s
    }

    func logoURL(for item: PlexItem) -> URL? {
        let show = shows[item.showKey] ?? item
        return imageURL(show.logoPath, width: 500, height: 200)
    }

    func imageURL(_ path: String?, width: Int, height: Int) -> URL? {
        guard let server else { return nil }
        let scale = 2
        return api.imageURL(server, path, width: width * scale, height: height * scale)
    }
    // MARK: playback

    /// Builds what the player needs: full metadata (for the file part) and the Plex resume point.
    func playRequest(for item: PlexItem, fromStart: Bool = false) async -> PlayRequest? {
        guard let server else { return nil }
        let full = (try? await api.metadata(server, item.ratingKey)) ?? item
        guard let part = full.partKey, let url = api.streamURL(server, partKey: part) else { return nil }
        var start = 0.0
        if !fromStart, let off = full.viewOffset, off > 0 { start = Double(off) / 1000 }
        return PlayRequest(url: url, title: full.displayTitle, subtitle: full.displaySubtitle,
                           start: start, plexItem: full, server: server)
    }

    func setWatched(_ item: PlexItem, _ watched: Bool) async {
        guard let server else { return }
        if watched { await api.scrobble(server, ratingKey: item.ratingKey) }
        else { await api.unscrobble(server, ratingKey: item.ratingKey) }
        await refreshHome()
    }
}
