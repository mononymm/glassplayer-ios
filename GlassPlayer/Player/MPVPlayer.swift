import Foundation
import UIKit
import AVFoundation
import Libmpv

/// A CAMetalLayer that works around MoltenVK quirks (same as the MPVKit demo).
final class MPVMetalLayer: CAMetalLayer {
    // MoltenVK sets drawableSize to 1x1 to force-complete presentation; ignore that.
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    // EDR (HDR) mode can only be switched on from the main thread.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
}

struct MPVTrack: Identifiable, Hashable {
    let id: Int
    let type: String          // "audio" / "sub" / "video"
    let title: String?
    let lang: String?
    let codec: String?
    let channels: Int?
    let isDefault: Bool
    let isExternal: Bool

    var label: String {
        var parts: [String] = []
        if let lang, !lang.isEmpty { parts.append(Locale.current.localizedString(forLanguageCode: lang) ?? lang.uppercased()) }
        if let title, !title.isEmpty, title != lang { parts.append(title) }
        if parts.isEmpty { parts.append("Track \(id)") }
        var extra: [String] = []
        if let codec, !codec.isEmpty { extra.append(MPVTrack.prettyCodec(codec)) }
        if let channels, channels > 0 { extra.append(MPVTrack.prettyChannels(channels)) }
        if isExternal { extra.append("External") }
        return extra.isEmpty ? parts.joined(separator: " · ") : parts.joined(separator: " · ") + "  (" + extra.joined(separator: " ") + ")"
    }

    static func prettyCodec(_ c: String) -> String {
        switch c.lowercased() {
        case "truehd": return "TrueHD"
        case "eac3": return "DD+"
        case "ac3": return "Dolby Digital"
        case "dts": return "DTS"
        case "dts-hd", "dtshd": return "DTS-HD"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "hevc", "h265": return "HEVC"
        case "h264", "avc": return "H.264"
        case "av1": return "AV1"
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "hdmv_pgs_subtitle", "pgs", "pgssub": return "PGS"
        case "dvd_subtitle", "vobsub": return "VobSub"
        default: return c.uppercased()
        }
    }

    static func prettyChannels(_ n: Int) -> String {
        switch n {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(n)ch"
        }
    }
}

/// Owns one libmpv instance. All UI-facing state is published on the main thread.
final class MPVPlayer: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var paused = false
    @Published var buffering = true
    @Published var ended = false
    @Published var loaded = false
    @Published var audioTracks: [MPVTrack] = []
    @Published var subTracks: [MPVTrack] = []
    @Published var aid: Int? = nil
    @Published var sid: Int? = nil
    @Published var mediaInfo: String = ""
    @Published var errorText: String? = nil
    @Published var chapterCount = 0
    @Published var chapterTimes: [Double] = []

    private(set) var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "glass.mpv", qos: .userInitiated)
    private var pendingURL: URL?
    private var pendingStart: Double = 0

    var hdr: Bool = UserDefaults.standard.object(forKey: "hdr") as? Bool ?? true

    // Observed property ids
    private enum Obs: UInt64 {
        case timePos = 1, duration, pause, cache, trackCount, aid, sid, eof, idle, chapters
    }

    deinit {
        if let mpv {
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
        }
    }

    // MARK: lifecycle

    func start(layer: MPVMetalLayer) {
        guard mpv == nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        guard let handle = mpv_create() else {
            errorText = "Couldn't start the player."
            return
        }
        mpv = handle

        var wid = layer
        check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid))
        set("vo", "gpu-next")
        set("gpu-api", "vulkan")
        set("gpu-context", "moltenvk")
        set("hwdec", "videotoolbox")
        set("video-rotate", "no")
        set("keep-open", "yes")
        set("idle", "yes")
        set("cache", "yes")
        set("demuxer-max-bytes", "200MiB")
        set("demuxer-max-back-bytes", "50MiB")
        set("subs-match-os-language", "yes")
        set("subs-fallback", "yes")
        set("sub-auto", "fuzzy")
        set("sub-font-size", "46")
        set("sub-border-size", "2.5")
        set("sub-shadow-offset", "1")
        set("audio-channels", "auto-safe")
        set("user-agent", "Glass/0.1 (iOS)")
        if hdr { set("target-colorspace-hint", "yes") }
        #if DEBUG
        mpv_request_log_messages(handle, "info")
        #endif

        check(mpv_initialize(handle))

        mpv_observe_property(handle, Obs.timePos.rawValue, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, Obs.duration.rawValue, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, Obs.pause.rawValue, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, Obs.cache.rawValue, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, Obs.trackCount.rawValue, "track-list/count", MPV_FORMAT_INT64)
        mpv_observe_property(handle, Obs.aid.rawValue, "aid", MPV_FORMAT_STRING)
        mpv_observe_property(handle, Obs.sid.rawValue, "sid", MPV_FORMAT_STRING)
        mpv_observe_property(handle, Obs.eof.rawValue, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, Obs.chapters.rawValue, "chapter-list/count", MPV_FORMAT_INT64)

        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            let player = Unmanaged<MPVPlayer>.fromOpaque(ctx).takeUnretainedValue()
            player.readEvents()
        }, Unmanaged.passUnretained(self).toOpaque())

        if let url = pendingURL {
            pendingURL = nil
            load(url, start: pendingStart)
        }
    }

    func stop() {
        guard let handle = mpv else { return }
        mpv = nil
        mpv_set_wakeup_callback(handle, nil, nil)
        queue.async {
            mpv_terminate_destroy(handle)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: control

    func load(_ url: URL, start: Double = 0) {
        guard mpv != nil else {
            pendingURL = url
            pendingStart = start
            return
        }
        DispatchQueue.main.async {
            self.loaded = false
            self.ended = false
            self.buffering = true
            self.position = start
        }
        set("start", start > 1 ? String(format: "%.3f", start) : "none")
        let target = url.isFileURL ? url.path : url.absoluteString
        command(["loadfile", target, "replace"])
    }

    func togglePause() { setProperty("pause", paused ? "no" : "yes") }
    func setPaused(_ p: Bool) { setProperty("pause", p ? "yes" : "no") }

    func seek(to seconds: Double) {
        command(["seek", String(format: "%.3f", max(0, seconds)), "absolute+exact"])
        DispatchQueue.main.async { self.position = max(0, seconds) }
    }

    func seek(by seconds: Double) {
        command(["seek", String(format: "%.3f", seconds), "relative"])
    }

    func chapter(_ delta: Int) {
        command(["add", "chapter", String(delta)])
    }

    func selectAudio(_ id: Int?) { setProperty("aid", id.map(String.init) ?? "no") }
    func selectSub(_ id: Int?) { setProperty("sid", id.map(String.init) ?? "no") }

    func setVideoEnabled(_ on: Bool) { setProperty("vid", on ? "auto" : "no") }

    /// The MoltenVK renderer doesn't watch for size changes, so re-open the video output
    /// (briefly switching the video track off and on) to make it pick up the new size.
    private var resizeWork: DispatchWorkItem?
    func surfaceResized() {
        guard mpv != nil else { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mpv != nil, self.loaded else { return }
            let vid = self.getString("vid") ?? "auto"
            guard vid != "no" else { return }
            self.setProperty("vid", "no")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.setProperty("vid", vid) }
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: low level

    private func set(_ name: String, _ value: String) {
        guard let mpv else { return }
        check(mpv_set_option_string(mpv, name, value))
    }

    func setProperty(_ name: String, _ value: String) {
        guard let mpv else { return }
        check(mpv_set_property_string(mpv, name, value))
    }

    func command(_ args: [String]) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer {
            for p in cargs { if let p { free(UnsafeMutablePointer(mutating: p)) } }
        }
        cargs.withUnsafeMutableBufferPointer { buf in
            _ = check(mpv_command(mpv, buf.baseAddress))
        }
    }

    func getString(_ name: String) -> String? {
        guard let mpv, let c = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    func getInt(_ name: String) -> Int? {
        guard let mpv else { return nil }
        var v: Int64 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &v) >= 0 ? Int(v) : nil
    }

    func getDouble(_ name: String) -> Double? {
        guard let mpv else { return nil }
        var v: Double = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    func getFlag(_ name: String) -> Bool {
        guard let mpv else { return false }
        var v: Int32 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &v)
        return v != 0
    }

    @discardableResult
    private func check(_ status: Int32) -> Int32 {
        if status < 0 {
            print("mpv error: \(String(cString: mpv_error_string(status)))")
        }
        return status
    }

    // MARK: events

    fileprivate func readEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            while let mpv = self.mpv {
                guard let event = mpv_wait_event(mpv, 0) else { break }
                let id = event.pointee.event_id
                if id == MPV_EVENT_NONE { break }
                self.handle(event.pointee)
                if id == MPV_EVENT_SHUTDOWN { break }
            }
        }
    }

    private func handle(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let raw = event.data else { return }
            let prop = raw.assumingMemoryBound(to: mpv_event_property.self).pointee
            handleProperty(id: event.reply_userdata, prop: prop)
        case MPV_EVENT_FILE_LOADED:
            let info = buildMediaInfo()
            DispatchQueue.main.async {
                self.loaded = true
                self.buffering = false
                self.mediaInfo = info
            }
            refreshTracks()
        case MPV_EVENT_END_FILE:
            if let raw = event.data {
                let end = raw.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    let msg = String(cString: mpv_error_string(end.error))
                    DispatchQueue.main.async { self.errorText = "Couldn't play this file (\(msg))." }
                }
            }
        case MPV_EVENT_VIDEO_RECONFIG, MPV_EVENT_AUDIO_RECONFIG:
            let info = buildMediaInfo()
            DispatchQueue.main.async { self.mediaInfo = info }
        case MPV_EVENT_LOG_MESSAGE:
            if let raw = event.data {
                let m = raw.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                print("[mpv \(String(cString: m.prefix))] \(String(cString: m.text))", terminator: "")
            }
        default:
            break
        }
    }

    private func handleProperty(id: UInt64, prop: mpv_event_property) {
        guard let obs = Obs(rawValue: id) else { return }
        let data = prop.data
        func dbl() -> Double? {
            guard prop.format == MPV_FORMAT_DOUBLE, let data else { return nil }
            return data.assumingMemoryBound(to: Double.self).pointee
        }
        func flag() -> Bool? {
            guard prop.format == MPV_FORMAT_FLAG, let data else { return nil }
            return data.assumingMemoryBound(to: Int32.self).pointee != 0
        }
        func str() -> String? {
            guard prop.format == MPV_FORMAT_STRING, let data,
                  let c = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return nil }
            return String(cString: c)
        }
        switch obs {
        case .timePos:
            if let v = dbl() { DispatchQueue.main.async { self.position = v } }
        case .duration:
            if let v = dbl() { DispatchQueue.main.async { self.duration = v } }
        case .pause:
            if let v = flag() { DispatchQueue.main.async { self.paused = v } }
        case .cache:
            if let v = flag() { DispatchQueue.main.async { self.buffering = v } }
        case .eof:
            if let v = flag() { DispatchQueue.main.async { self.ended = v } }
        case .trackCount:
            refreshTracks()
        case .aid:
            let v = str().flatMap { Int($0) }
            DispatchQueue.main.async { self.aid = v }
            let info = buildMediaInfo()
            DispatchQueue.main.async { self.mediaInfo = info }
        case .sid:
            let v = str().flatMap { Int($0) }
            DispatchQueue.main.async { self.sid = v }
        case .chapters:
            let n = getInt("chapter-list/count") ?? 0
            let times = (0..<n).compactMap { getDouble("chapter-list/\($0)/time") }
            DispatchQueue.main.async {
                self.chapterCount = n
                self.chapterTimes = times
            }
        case .idle:
            break
        }
    }

    private func refreshTracks() {
        let count = getInt("track-list/count") ?? 0
        var audio: [MPVTrack] = []
        var subs: [MPVTrack] = []
        for i in 0..<count {
            let p = "track-list/\(i)/"
            guard let type = getString(p + "type"), let tid = getInt(p + "id") else { continue }
            let t = MPVTrack(
                id: tid,
                type: type,
                title: getString(p + "title"),
                lang: getString(p + "lang"),
                codec: getString(p + "codec"),
                channels: getInt(p + "demux-channel-count"),
                isDefault: getString(p + "default") == "yes",
                isExternal: getString(p + "external") == "yes"
            )
            if type == "audio" { audio.append(t) } else if type == "sub" { subs.append(t) }
        }
        DispatchQueue.main.async {
            self.audioTracks = audio
            self.subTracks = subs
        }
    }

    /// "2160p · HEVC · HDR10 · TrueHD 7.1" — same idea as the desktop Glass panel.
    func buildMediaInfo() -> String {
        var parts: [String] = []
        if let h = getInt("video-params/h"), h > 0 {
            let w = getInt("video-params/w") ?? 0
            let label: String
            if w >= 3200 || h >= 1800 { label = "2160p" }
            else if w >= 1800 || h >= 1000 { label = "1080p" }
            else if w >= 1200 || h >= 700 { label = "720p" }
            else { label = "\(h)p" }
            parts.append(label)
        }
        if let v = getString("video-format") ?? getString("video-codec-name") {
            parts.append(MPVTrack.prettyCodec(v))
        }
        if let gamma = getString("video-params/gamma") {
            if gamma == "pq" { parts.append("HDR10") }
            else if gamma == "hlg" { parts.append("HLG") }
        }
        // average bitrate of the whole file, like Plex shows it
        if let size = getInt("file-size"), let dur = getDouble("duration"), size > 0, dur > 1 {
            let mbps = Double(size) * 8 / dur / 1_000_000
            parts.append(mbps >= 10 ? String(format: "%.0f Mbps", mbps) : String(format: "%.1f Mbps", mbps))
        }
        if let a = getString("audio-codec-name") {
            var s = MPVTrack.prettyCodec(a)
            if let ch = getInt("audio-params/channel-count"), ch > 0 { s += " " + MPVTrack.prettyChannels(ch) }
            parts.append(s)
        }
        return parts.joined(separator: " · ")
    }
}
