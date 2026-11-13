# Glass for iPhone

A personal video player for iPhone and iPad: **mpv** (via [MPVKit](https://github.com/mpvkit/MPVKit)) under a native SwiftUI interface with Liquid Glass, connected to Plex.

- Plays anything mpv plays — TrueHD, DTS / DTS-HD, Atmos cores, PGS subtitles, ASS, HEVC / HDR10 — with direct play from Plex (no transcoding).
- Sign in with Plex (plex.tv/link), Continue watching, libraries, shows and seasons, search.
- Watch progress goes back to Plex as you watch; 90% counts as watched.
- Gestures: double-tap left −10 s, right +30 s · hold right for 2×, hold left to rewind · tap to show controls.
- Local files: Files app → On My iPhone → Glass, or "Open in Glass".

## Getting it on your phone

Every push to `main` builds an unsigned `GlassPlayer.ipa` (Actions → latest run, or the **latest** release):
https://github.com/mononymm/glassplayer-ios/releases/download/latest/GlassPlayer.ipa

1. On Windows, install iTunes (the apple.com version, not the Microsoft Store one) and the latest [Sideloadly](https://sideloadly.io).
2. Plug in the iPhone, unlock it and tap **Trust**.
3. Drag `GlassPlayer.ipa` into Sideloadly, enter your Apple ID, click **Start**.
4. On the iPhone: Settings → General → VPN & Device Management → your Apple ID → **Trust**.
5. If asked, turn on Settings → Privacy & Security → **Developer Mode** and restart.

With a free Apple ID the app has to be re-installed from Sideloadly every 7 days (your Plex sign-in and settings are kept).

The Xcode project is generated from `project.yml` with XcodeGen.
