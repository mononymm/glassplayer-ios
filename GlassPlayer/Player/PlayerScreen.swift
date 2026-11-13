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
    @State private var queue: [PlexItem] = []
    @State private var showPlaylist = false
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

            // loading: with the controls up, the play button shows it; otherwise a plain spinner
            if player.buffering && !player.paused && !controlsVisible {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .shadow(color: .black.opacity(0.6), radius: 6)
                    .allowsHitTesting(false)
            }

            seekFlash
            holdBadge

            if controlsVisible {
                controls
                    .transition(.opacity)
            }

            if showPlaylist {
                playlistPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if let err = player.errorText {
                errorCard(err)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
        .animation(.spring(duration: 0.35), value: showPlaylist)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            Orientation.lock(.landscape)
            UIApplication.shared.isIdleTimerDisabled = true
            player.load(request.url, start: request.start)
            scheduleHide()
            startReporting()
            Task { await loadQueue() }
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
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 190)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack {
                    Button { close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    Spacer()
                }
                Spacer()
                centerButtons
                Spacer()
                titleOverlay
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
        }
    }

    private var centerButtons: some View {
        GlassEffectContainer(spacing: 30) {
            HStack(spacing: 30) {
                Button { player.chapter(-1); poke() } label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .opacity(hasChapters ? 1 : 0.35)
                .disabled(!hasChapters)

                Button {
                    if player.ended { player.seek(to: 0); player.setPaused(false) } else { player.togglePause() }
                    poke()
                } label: {
                    PlayGlyph(paused: player.paused, ended: player.ended, loading: player.buffering && !player.paused)
                }
                .buttonStyle(.plain)

                Button { player.chapter(1); poke() } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .opacity(hasChapters ? 1 : 0.35)
                .disabled(!hasChapters)
            }
        }
    }

    private var hasChapters: Bool { player.chapterCount > 1 }

    /// Title sits on the video with a soft shadow instead of in a capsule.
    private var titleOverlay: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                if let sub = request.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    Text(clockLine(ctx.date))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.9))
                }
                Text(infoLine)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.45), radius: 10)
    }

    /// One thin, clear glass strip: time, seek bar, remaining, speed, audio, subtitles, playlist.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            (Text(formatTime(scrubbing ? scrubValue : player.position))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
             + Text(" / " + formatTime(player.duration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.6)))
                .lineLimit(1)
                .fixedSize()

            SeekBar(
                position: player.position,
                duration: player.duration,
                chapters: player.chapterTimes,
                watchedAt: request.plexItem != nil ? watchedAt : nil,
                scrubbing: $scrubbing,
                scrubValue: $scrubValue,
                onCommit: { t in player.seek(to: t); poke() },
                onScrubChange: { poke(autoHide: false) }
            )

            Rectangle().fill(.white.opacity(0.25)).frame(width: 0.5, height: 20)

            speedMenu
            audioMenu
            subtitleMenu
            Button { poke(autoHide: false); showPlaylist = true; controlsVisible = false } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(queue.isEmpty ? 0.35 : 1)
            .disabled(queue.isEmpty)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 46)
        .glassEffect(.clear, in: .capsule)
    }

    /// "4:12 PM · ends 4:35 PM" (accounts for playback speed)
    private func clockLine(_ now: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        var line = f.string(from: now)
        let left = max(0, player.duration - player.position) / max(0.1, speed)
        if player.duration > 0 { line += "  ·  ends " + f.string(from: now.addingTimeInterval(left)) }
        return line
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
            Text(String(format: "%g×", speed))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var audioMenu: some View {
        Menu {
            Picker("Audio", selection: Binding(get: { player.aid ?? -1 }, set: { player.selectAudio($0 < 0 ? nil : $0); poke() })) {
                ForEach(player.audioTracks) { t in Text(t.label).tag(t.id) }
            }
        } label: {
            Image(systemName: "music.note")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(player.audioTracks.isEmpty)
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
                .foregroundStyle(player.sid == nil ? Color.white : Theme.accent)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    /// Episodes of the current season, in a glass panel on the right.
    private var playlistPanel: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(request.plexItem?.parentTitle ?? "Up next")
                        .font(.system(size: 15, weight: .bold))
                    Spacer()
                    Button { showPlaylist = false; showControls() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(queue) { ep in
                                let current = ep.ratingKey == request.plexItem?.ratingKey
                                Button { if !current { play(ep) } } label: {
                                    HStack(spacing: 10) {
                                        PosterImage(url: plex.imageURL(ep.thumb, width: 120, height: 68), corner: 8)
                                            .frame(width: 86, height: 48)
                                            .overlay(alignment: .bottom) {
                                                if let p = ep.progress, !current { ProgressLine(value: p).padding(4) }
                                            }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(ep.episodeCode ?? "")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(current ? Theme.accent : .white.opacity(0.6))
                                            Text(ep.title)
                                                .font(.system(size: 13, weight: current ? .bold : .medium))
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                        }
                                        Spacer(minLength: 0)
                                        if current {
                                            Image(systemName: "waveform").foregroundStyle(Theme.accent)
                                                .symbolEffect(.variableColor.iterative, isActive: !player.paused)
                                        } else if ep.watched {
                                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.5))
                                        }
                                    }
                                    .padding(8)
                                    .background(current ? Color.white.opacity(0.12) : .clear, in: .rect(cornerRadius: 14))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(ep.ratingKey)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                    }
                    .onAppear {
                        if let k = request.plexItem?.ratingKey { proxy.scrollTo(k, anchor: .center) }
                    }
                }
            }
            .frame(width: 330)
            .foregroundStyle(.white)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .padding(.vertical, 12)
            .padding(.trailing, 12)
        }
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

    // MARK: - playlist

    /// The current season's episodes (or nothing for movies and local files).
    private func loadQueue() async {
        guard let item = request.plexItem, item.isEpisode, let server = request.server,
              let season = item.parentRatingKey else { queue = []; return }
        queue = (try? await plex.api.children(server, of: season)) ?? []
    }

    private func play(_ next: PlexItem) {
        let pos = player.position, dur = player.duration
        let old = request
        Task { await finalReport(position: pos, duration: dur, request: old) }
        Task { @MainActor in
            guard let server = request.server,
                  let full = try? await plex.api.metadata(server, next.ratingKey) ?? next,
                  let part = full.partKey,
                  let url = plex.api.streamURL(server, partKey: part) else { return }
            var start = 0.0
            if let off = full.viewOffset, off > 0, !(full.watched) { start = Double(off) / 1000 }
            let seasonChanged = full.parentRatingKey != request.plexItem?.parentRatingKey
            request = PlayRequest(url: url, title: full.displayTitle, subtitle: full.displaySubtitle,
                                  start: start, plexItem: full, server: server)
            scrobbled = false
            showPlaylist = false
            player.load(url, start: start)
            showControls()
            if seasonChanged { await loadQueue() }
        }
    }
}

/// Slim seek bar. Touch jumps to the finger; dragging is relative, and sliding the finger
/// up away from the bar slows scrubbing down (half, quarter, fine) like Apple's players.
struct SeekBar: View {
    let position: Double
    let duration: Double
    var chapters: [Double] = []
    let watchedAt: Double?
    @Binding var scrubbing: Bool
    @Binding var scrubValue: Double
    var onCommit: (Double) -> Void
    var onScrubChange: () -> Void

    @State private var lastX: CGFloat = 0
    @State private var rate: Double = 1
    private let haptic = UISelectionFeedbackGenerator()

    private static func rate(forLift lift: CGFloat) -> Double {
        if lift < 50 { return 1 }
        if lift < 110 { return 0.5 }
        if lift < 170 { return 0.25 }
        return 0.1
    }

    private var rateLabel: String? {
        switch rate {
        case 0.5: return "Half-speed scrubbing"
        case 0.25: return "Quarter-speed scrubbing"
        case 0.1: return "Fine scrubbing"
        default: return nil
        }
    }

    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width)
            let frac = duration > 0 ? min(1, max(0, (scrubbing ? scrubValue : position) / duration)) : 0
            let barH: CGFloat = scrubbing ? 7 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: barH)
                Capsule().fill(Theme.accent)
                    .frame(width: max(0, w * frac), height: barH)
                    .shadow(color: Theme.accent.opacity(0.6), radius: 5)
                ForEach(Array(chapters.enumerated()), id: \.offset) { pair in
                    let t = pair.element
                    if duration > 0, t > 0, t < duration {
                        Rectangle().fill(.black.opacity(0.45))
                            .frame(width: 1.5, height: barH)
                            .offset(x: w * t / duration - 0.75)
                    }
                }
                if let watchedAt, duration > 0 {
                    Triangle()
                        .fill(.white.opacity(0.7))
                        .frame(width: 7, height: 5)
                        .offset(x: w * watchedAt - 3.5, y: -8)
                }
                Circle()
                    .fill(.white)
                    .frame(width: scrubbing ? 18 : 11, height: scrubbing ? 18 : 11)
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .offset(x: w * frac - (scrubbing ? 9 : 5.5))
                if scrubbing {
                    VStack(spacing: 3) {
                        Text(formatTime(scrubValue))
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                        if let rateLabel {
                            Text(rateLabel).font(.system(size: 10, weight: .semibold)).opacity(0.85)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .fixedSize()
                    .offset(x: min(max(0, w * frac - 40), w - 80), y: rateLabel == nil ? -34 : -40)
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 34)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        guard duration > 0 else { return }
                        if !scrubbing {
                            // First touch: jump to the finger.
                            scrubbing = true
                            rate = 1
                            lastX = v.location.x
                            scrubValue = min(duration, max(0, Double(v.location.x / w) * duration))
                            haptic.prepare()
                        } else {
                            let lift = max(0, 17 - v.location.y)   // points above the bar's middle
                            let r = SeekBar.rate(forLift: lift)
                            if r != rate { rate = r; haptic.selectionChanged() }
                            let dx = v.location.x - lastX
                            lastX = v.location.x
                            scrubValue = min(duration, max(0, scrubValue + Double(dx / w) * duration * rate))
                        }
                        onScrubChange()
                    }
                    .onEnded { _ in
                        guard duration > 0 else { return }
                        onCommit(scrubValue)
                        scrubbing = false
                        rate = 1
                    }
            )
            .animation(.easeOut(duration: 0.15), value: scrubbing)
            .animation(.easeOut(duration: 0.15), value: rate)
        }
        .frame(height: 34)
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


/// Clear glass play button: see-through middle, a shiny red glass rim with a red glow,
/// and the play/pause symbol drawn as a red outline.
struct PlayGlyph: View {
    let paused: Bool
    let ended: Bool
    let loading: Bool

    private let red = Theme.accent
    private let redLight = Color(red: 1, green: 0.70, blue: 0.69)

    var body: some View {
        ZStack {
            // red glow just outside the rim
            Circle()
                .stroke(red.opacity(0.55), lineWidth: 5)
                .blur(radius: 5)
            // shiny red rim: bright where the light catches it (top-left, bottom-right), softer between
            Circle()
                .strokeBorder(
                    AngularGradient(stops: [
                        .init(color: redLight, location: 0.00),
                        .init(color: red.opacity(0.55), location: 0.18),
                        .init(color: red.opacity(0.25), location: 0.38),
                        .init(color: redLight.opacity(0.9), location: 0.50),
                        .init(color: red.opacity(0.30), location: 0.68),
                        .init(color: red.opacity(0.55), location: 0.85),
                        .init(color: redLight, location: 1.00),
                    ], center: .center, angle: .degrees(-135)),
                    lineWidth: 2.2
                )
            symbol
        }
        .frame(width: 64, height: 64)
        .glassEffect(.clear.interactive(), in: .circle)
        .contentShape(Circle())
    }

    @ViewBuilder private var symbol: some View {
        if loading {
            ProgressView().tint(red)
        } else if ended {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(red)
                .shadow(color: red.opacity(0.6), radius: 4)
        } else {
            ZStack {
                if paused {
                    PlayOutline()
                        .stroke(red, style: StrokeStyle(lineWidth: 2.6, lineJoin: .round))
                        .frame(width: 20, height: 24)
                        .offset(x: 2)                       // the triangle's weight sits left of its box
                } else {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).stroke(red, lineWidth: 2.4).frame(width: 6, height: 23)
                        RoundedRectangle(cornerRadius: 2).stroke(red, lineWidth: 2.4).frame(width: 6, height: 23)
                    }
                }
            }
            .shadow(color: red.opacity(0.7), radius: 4)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
            .id(paused)
            .animation(.spring(duration: 0.28), value: paused)
        }
    }
}

struct PlayOutline: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
