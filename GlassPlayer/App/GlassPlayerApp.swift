import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.mask
    }
}

@main
struct GlassPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var plex = PlexStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(plex)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var plex: PlexStore
    @State private var playing: PlayRequest?

    var body: some View {
        Group {
            if plex.signedIn {
                HomeView(play: { playing = $0 })
            } else {
                SignInView(play: { playing = $0 })
            }
        }
        .fullScreenCover(item: $playing) { req in
            PlayerScreen(request: req)
                .environmentObject(plex)
        }
        .onOpenURL { url in
            // "Open in Glass" from Files or other apps.
            playing = LocalFiles.request(for: url)
        }
    }
}
