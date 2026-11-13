import SwiftUI
import UIKit

/// What to play. Either a Plex item on a server, or a local file.
struct PlayRequest: Identifiable {
    let id = UUID()
    var url: URL
    var title: String
    var subtitle: String?
    var start: Double = 0
    var plexItem: PlexItem? = nil
    var server: PlexServer? = nil
    var localKey: String? = nil
}

/// Remembers resume points for files that aren't in Plex.
enum LocalPositions {
    private static let key = "localPositions"
    static func get(_ k: String) -> Double {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[k] ?? 0
    }
    static func set(_ k: String, _ v: Double) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        d[k] = v
        UserDefaults.standard.set(d, forKey: key)
    }
}

struct PlayerScreen: View {
    @EnvironmentObject var plex: PlexStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = MPVPlayer()

    @State var request: PlayRequest

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var flash: (side: ScreenSide, text: String)?
    @State private var flashTask: Task<Void, Never>?
    @State private var holdMode: ScreenSide?
    @State private var rewindTask: Task<Void, Never>?
    @State private var wasPausedBeforeRewind = false
    @State private var reportTask: Task<Void, Never>?
    @State private var nextItem: PlexItem?
    @State private var scrobbled = false
    @State private var speed: Double = 1

    private let watchedAt = 0.90

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MPVVideoView(player: player)
                .ignoresSafeArea()

            GestureLayer(
                onTap: { toggleControls() },
                onDoubleTap: { side in doubleTap(side) },
                onHoldBegan: { side in holdBegan(side) },
                onHoldEnded: { holdEnded() }
            )
            .ignoresSafeArea()

            if player.buffering && !player.paused {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(22)
                    .glassEffect(.regular, in: .circle)
                    .allowsHitTesting(false)
            }

            seekFlash
            holdBadge

            if controlsVisible {
                controls
                    .transition(.opacity)
            }

            if let err = player.errorText {
                errorCard(err)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            Orientation.lock(.landscape)
            UIApplication.shared.isIdleTimerDisabled = true
            player.load(request.url, start: request.start)
            scheduleHide()
            startReporting()
            Task { await findNext() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Orientation.lock(.all)
        }
        .onChange(of: player.paused) { _, paused in
            if paused { showControls(autoHide: false) } else { scheduleHide() }
            Task { await report(state: paused ? "paused" : "playing") }
        }
        .onChange(of: player.ended) { _, ended in
            if ended { showControls(autoHide: false) }
        }
    }

    // MARK: - controls

    private var controls: some View {
        ZStack {
            // Soft scrims so white text reads over bright video.
            VStack {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerButtons
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { close() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(request.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                if let sub = request.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)

            Spacer()

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    speedMenu
                    audioMenu
                    subtitleMenu
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var centerButtons: some View {
        GlassEffectContainer(spacing: 28) {
            HStack(spacing: 28) {
                Button { player.seek(by: -10); poke() } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 26, weight: .medium))
                        .frame(width: 64, height: 64)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                Button {
                    if player.ended { player.seek(to: 0); player.setPaused(false) } else { player.togglePause() }
                    poke()
                } label: {
                    Image(systemName: player.ended ? "arrow.counterclockwise" : (player.paused ? "play.fill" : "pause.fill"))
                        .font(.system(size: 34, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 84, height: 84)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(Theme.accent)

                Button { player.seek(by: 30); poke() } label: {
                    Image(systemName: "goforward.30").font(.system(size: 26, weight: .medium))
                        .frame(width: 64, height: 64)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
        }
        .foregroundStyle(.white)
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(formatTime(scrubbing ? scrubValue : player.position))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Text("/ " + formatTime(player.duration))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 12)
                Text(infoLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            SeekBar(
                position: player.position,
                duration: player.duration,
                watchedAt: request.plexItem != nil ? watchedAt : nil,
                scrubbing: $scrubbing,
                scrubValue: $scrubValue,
                onCommit: { t in player.seek(to: t); poke() },
                onScrubChange: { poke(autoHide: false) }
            )

            if nextItem != nil || player.ended {
                HStack {
                    Spacer()
                    if let next = nextItem {
                        Button { playNext(next) } label: {
                            Label("Next: " + (next.episodeCode ?? next.title), systemImage: "forward.end.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glassEffect(.regular.tint(Theme.tint.opacity(0.35)), in: .rect(cornerRadius: 26))
    }

    private var infoLine: String {
        let fromPlex = request.plexItem?.mediaSummary ?? ""
        return player.mediaInfo.isEmpty ? fromPlex : player.mediaInfo
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { speed }, set: { setSpeed($0) })) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
                    Text(s == 1 ? "Normal" : String(format: "%g×", s)).tag(s)
                }
            }
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    private var audioMenu: some View {
        Menu {
            Picker("Audio", selection: Binding(get: { player.aid ?? -1 }, set: { player.selectAudio($0 < 0 ? nil : $0); poke() })) {
                ForEach(player.audioTracks) { t in Text(t.label).tag(t.id) }
            }
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(player.audioTracks.count < 1)
    }

    private var subtitleMenu: some View {
        Menu {
            Picker("Subtitles", selection: Binding(get: { player.sid ?? -1 }, set: { player.selectSub($0 < 0 ? nil : $0); poke() })) {
                Text("Off").tag(-1)
                ForEach(player.subTracks) { t in Text(t.label).tag(t.id) }
            }
        } label: {
            Image(systemName: player.sid == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    // MARK: - gesture feedback

    @ViewBuilder private var seekFlash: some View {
        if let flash {
            HStack {
                if flash.side == .right { Spacer() }
                Label(flash.text, systemImage: flash.side == .left ? "gobackward" : "goforward")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 70)
                if flash.side == .left { Spacer() }
            }
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    @ViewBuilder private var holdBadge: some View {
        if let holdMode {
            VStack {
                Label(holdMode == .right ? "2×" : "2× rewind",
                      systemImage: holdMode == .right ? "forward.fill" : "backward.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(Theme.accent.opacity(0.35)), in: .capsule)
                    .padding(.top, 24)
                Spacer()
            }
            .allowsHitTesting(false)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func errorCard(_ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Theme.accent)
            Text(text).multilineTextAlignment(.center)
            Button("Close") { close() }.buttonStyle(.glassProminent).tint(Theme.accent)
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    // MARK: - behaviour

    private func toggleControls() {
        if controlsVisible { controlsVisible = false; hideTask?.cancel() } else { showControls() }
    }

    private func showControls(autoHide: Bool = true) {
        controlsVisible = true
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func poke(autoHide: Bool = true) { showControls(autoHide: autoHide) }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if Task.isCancelled { return }
            if !player.paused && !scrubbing && !player.ended { controlsVisible = false }
        }
    }

    private func doubleTap(_ side: ScreenSide) {
        let delta: Double = side == .left ? -10 : 30
        player.seek(by: delta)
        flashTask?.cancel()
        withAnimation(.spring(duration: 0.25)) { flash = (side, side == .left ? "10 s" : "30 s") }
        flashTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.25)) { flash = nil }
        }
    }

    private func holdBegan(_ side: ScreenSide) {
        withAnimation(.spring(duration: 0.25)) { holdMode = side }
        if side == .right {
            player.setProperty("speed", "2")
        } else {
            // mpv can't decode backwards smoothly, so rewind in quick steps (about 2× speed).
            wasPausedBeforeRewind = player.paused
            player.setPaused(true)
            rewindTask?.cancel()
            rewindTask = Task { @MainActor in
                while !Task.isCancelled {
                    player.seek(by: -0.5)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
    }

    private func holdEnded() {
        guard let mode = holdMode else { return }
        withAnimation(.easeOut(duration: 0.2)) { holdMode = nil }
        if mode == .right {
            player.setProperty("speed", String(speed))
        } else {
            rewindTask?.cancel()
            rewindTask = nil
            player.setPaused(wasPausedBeforeRewind)
        }
    }

    private func setSpeed(_ s: Double) {
        speed = s
        player.setProperty("speed", String(s))
        poke()
    }

    private func close() {
        reportTask?.cancel()
        let pos = player.position, dur = player.duration
        let req = request
        Task { await finalReport(position: pos, duration: dur, request: req) }
        player.stop()
        dismiss()
    }

    // MARK: - Plex progress

    private func startReporting() {
        reportTask?.cancel()
        reportTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                if !player.paused && player.loaded {
                    await report(state: "playing")
                }
                if let key = request.localKey, player.position > 5 {
                    LocalPositions.set(key, player.position)
                }
                await checkScrobble()
            }
        }
    }

    private func report(state: String) async {
        guard let item = request.plexItem, let server = request.server, player.duration > 0 else { return }
        await plex.api.timeline(server, ratingKey: item.ratingKey, state: state,
                                timeMs: Int(player.position * 1000), durationMs: Int(player.duration * 1000))
    }

    private func checkScrobble() async {
        guard !scrobbled, let item = request.plexItem, let server = request.server,
              player.duration > 0, player.position / player.duration >= watchedAt else { return }
        scrobbled = true
        await plex.api.scrobble(server, ratingKey: item.ratingKey)
    }

    private func finalReport(position: Double, duration: Double, request: PlayRequest) async {
        if let key = request.localKey {
            LocalPositions.set(key, duration > 0 && position / duration >= watchedAt ? 0 : position)
        }
        guard let item = request.plexItem, let server = request.server, duration > 0 else { return }
        let done = position / duration >= watchedAt
        if done {
            await plex.api.scrobble(server, ratingKey: item.ratingKey)
            await plex.api.timeline(server, ratingKey: item.ratingKey, state: "stopped",
                                    timeMs: Int(duration * 1000), durationMs: Int(duration * 1000))
        } else if position >= 10 {
            await plex.api.timeline(server, ratingKey: item.ratingKey, state: "stopped",
                                    timeMs: Int(position * 1000), durationMs: Int(duration * 1000))
        }
        await plex.refreshHome()
    }

    // MARK: - next episode

    private func findNext() async {
        guard let item = request.plexItem, item.isEpisode, let server = request.server,
              let season = item.parentRatingKey else { return }
        let eps = (try? await plex.api.children(server, of: season)) ?? []
        if let i = eps.firstIndex(where: { $0.ratingKey == item.ratingKey }), i + 1 < eps.count {
            nextItem = eps[i + 1]
            return
        }
        // Last of the season: first episode of the next season.
        guard let show = item.grandparentRatingKey else { return }
        let seasons = (try? await plex.api.children(server, of: show)) ?? []
        if let si = seasons.firstIndex(where: { $0.ratingKey == season }), si + 1 < seasons.count {
            let nextEps = (try? await plex.api.children(server, of: seasons[si + 1].ratingKey)) ?? []
            nextItem = nextEps.first
        }
    }

    private func playNext(_ next: PlexItem) {
        let pos = player.position, dur = player.duration
        let old = request
        Task { await finalReport(position: pos, duration: dur, request: old) }
        Task { @MainActor in
            guard let server = request.server,
                  let full = try? await plex.api.metadata(server, next.ratingKey) ?? next,
                  let part = full.partKey,
                  let url = plex.api.streamURL(server, partKey: part) else { return }
            request = PlayRequest(url: url, title: full.displayTitle, subtitle: full.displaySubtitle,
                                  start: 0, plexItem: full, server: server)
            scrobbled = false
            nextItem = nil
            player.load(url, start: 0)
            await findNext()
        }
    }
}

/// Slim seek bar with glow, a draggable thumb and the 90% "counts as watched" marker.
struct SeekBar: View {
    let position: Double
    let duration: Double
    let watchedAt: Double?
    @Binding var scrubbing: Bool
    @Binding var scrubValue: Double
    var onCommit: (Double) -> Void
    var onScrubChange: () -> Void

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let frac = duration > 0 ? min(1, max(0, (scrubbing ? scrubValue : position) / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: scrubbing ? 8 : 5)
                Capsule().fill(Theme.accent)
                    .frame(width: max(0, w * frac), height: scrubbing ? 8 : 5)
                    .shadow(color: Theme.accent.opacity(0.7), radius: 6)
                if let watchedAt, duration > 0 {
                    Triangle()
                        .fill(.white.opacity(0.75))
                        .frame(width: 8, height: 6)
                        .offset(x: w * watchedAt - 4, y: -10)
                }
                Circle()
                    .fill(.white)
                    .frame(width: scrubbing ? 22 : 14, height: scrubbing ? 22 : 14)
                    .shadow(color: .black.opacity(0.35), radius: 4)
                    .offset(x: w * frac - (scrubbing ? 11 : 7))
                if scrubbing {
                    Text(formatTime(scrubValue))
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .offset(x: min(max(0, w * frac - 30), w - 64), y: -34)
                }
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard duration > 0 else { return }
                        if !scrubbing { scrubbing = true }
                        scrubValue = min(duration, max(0, Double(v.location.x / w) * duration))
                        onScrubChange()
                    }
                    .onEnded { _ in
                        guard duration > 0 else { return }
                        onCommit(scrubValue)
                        scrubbing = false
                    }
            )
            .animation(.easeOut(duration: 0.15), value: scrubbing)
        }
        .frame(height: 30)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Lets the player force landscape and the rest of the app rotate freely.
enum Orientation {
    static var mask: UIInterfaceOrientationMask = .all

    static func lock(_ m: UIInterfaceOrientationMask) {
        mask = m
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: m)) { _ in }
        for w in scene.windows {
            w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            w.rootViewController?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}
