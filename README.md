# Glass for iPhone

A personal video player for iPhone and iPad: **mpv** (via [MPVKit](https://github.com/mpvkit/MPVKit)) under a native SwiftUI interface with Liquid Glass, connected to Plex.

- Plays anything mpv plays — TrueHD, DTS / DTS-HD, Atmos cores, PGS subtitles, ASS, HEVC / HDR10 — with direct play from Plex (no transcoding).
- Sign in with Plex (plex.tv/link), Continue watching, libraries, shows and seasons, search.
- Watch progress goes back to Plex as you watch; 90% counts as watched.
- Gestures: double-tap left −10 s, right +30 s · hold right for 2×, hold left to rewind · tap to show controls.
- Local files: Files app → On My iPhone → Glass, or "Open in Glass".

## Getting it on your phone

Every push to `main` builds an unsigned `GlassPlayer.ipa` in GitHub Actions (Actions tab → latest run → *GlassPlayer-ipa*, or the **latest** release). Install it with [Sideloadly](https://sideloadly.io) using your Apple ID. With a free Apple ID the app must be re-signed every 7 days.

The Xcode project is generated from `project.yml` with XcodeGen.
