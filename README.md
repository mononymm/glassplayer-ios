# Glass for iPhone

> **Personal project — not made for public use.** It's built for one setup and one phone, it isn't on
> the App Store, and it may not work for you. There's no support, no warranty, and things change often.
> Use it at your own risk.

A video player for iPhone and iPad: **mpv** (via [MPVKit](https://github.com/mpvkit/MPVKit)) under a
native SwiftUI interface with Liquid Glass, connected to Plex.

- Plays what mpv plays (TrueHD, DTS, PGS and ASS subtitles, HEVC, HDR) by direct play from Plex
- Sign in with a plex.tv/link code; home with backdrops and title logos, Continue watching, libraries, search
- Watch progress goes back to Plex while you watch; 90% counts as watched
- Gestures: double-tap left −10 s, right +30 s · hold right for 2×, hold left to rewind · tap for controls

## Quick start (if you want to try it anyway)

You need a Plex server, a Windows PC or Mac, and an Apple ID (a free one works).

1. Download `GlassPlayer.ipa` from the [latest release](../../releases/latest).
2. Install it with [Sideloadly](https://sideloadly.io): plug in the iPhone, unlock it and tap **Trust**,
   drag the `.ipa` into Sideloadly, enter your Apple ID and click **Start**.
3. On the iPhone: Settings → General → VPN & Device Management → your Apple ID → **Trust**. If asked,
   turn on Settings → Privacy & Security → **Developer Mode** and restart.
4. Open Glass, tap **Sign in with Plex** and enter the code at plex.tv/link.

With a free Apple ID the app must be reinstalled every 7 days (your sign-in is kept).

**Privacy:** your Plex sign-in token is stored only in the iPhone's Keychain. The app talks only to
plex.tv (sign-in and finding your server) and to your own Plex server.

## Is it safe? Verify a download, or build it yourself

All the code is in this repository, and every release is built by GitHub Actions straight from it
(the build logs are public under **Actions**). Each release lists the SHA-256 fingerprint of the
`.ipa` and carries a signed build certificate that ties it to the exact commit and build:

```
gh attestation verify GlassPlayer.ipa --repo mononymm/glassplayer-ios
```

(needs the [GitHub CLI](https://cli.github.com)). Sideloadly re-signs the app with your own Apple ID
when it installs it.

**Build it yourself** on a Mac with Xcode 26 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```
git clone https://github.com/mononymm/glassplayer-ios
cd glassplayer-ios
xcodegen generate
open GlassPlayer.xcodeproj
```

Then pick your iPhone and press Run (Xcode signs it with your Apple ID).
