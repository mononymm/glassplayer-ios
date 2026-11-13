import SwiftUI

enum Theme {
    static let accent = Color(red: 0xF0 / 255, green: 0x30 / 255, blue: 0x2C / 255)
    static let background = Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x13 / 255)
    static let tint = Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1C / 255)
    static let secondaryText = Color.white.opacity(0.6)
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

/// Poster image from Plex with a soft placeholder.
struct PosterImage: View {
    let url: URL?
    var corner: CGFloat = 14

    var body: some View {
        // The tile's size comes from outside (frame / aspect ratio); the picture fills it and is cut to
        // it. Clipping the picture itself would let a wide or tall image spill past the tile.
        Rectangle().fill(Theme.tint)
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Image(systemName: "film").font(.title2).foregroundStyle(.white.opacity(0.18))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Thin red progress line under a card.
struct ProgressLine: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(Theme.accent).frame(width: max(4, g.size.width * value))
                    .shadow(color: Theme.accent.opacity(0.6), radius: 4)
            }
        }
        .frame(height: 4)
    }
}

/// Small check badge for watched items.
struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(6)
            .glassEffect(.regular.tint(Theme.accent.opacity(0.7)), in: .circle)
    }
}
