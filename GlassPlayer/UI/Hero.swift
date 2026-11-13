import SwiftUI

/// Big backdrop with the title logo, like the Windows app's home page. Rotates through items.
struct HeroCarousel: View {
    @EnvironmentObject var plex: PlexStore
    let items: [PlexItem]
    var play: (PlexItem) -> Void
    var details: (PlexItem) -> Void

    @State private var index = 0
    @State private var timer = Timer.publish(every: 9, on: .main, in: .common).autoconnect()

    var body: some View {
        let item = items.isEmpty ? nil : items[index % items.count]
        ZStack(alignment: .bottomLeading) {
            if let item {
                ArtBackdrop(url: plex.imageURL(item.backdropPath ?? item.stillPath, width: 960, height: 540))
                    .id(item.ratingKey)
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 10) {
                    TitleLogo(item: item, maxWidth: 260, maxHeight: 96)
                    Text(meta(item))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let p = item.progress {
                        HStack(spacing: 10) {
                            ProgressLine(value: p).frame(width: 120)
                            Text(item.remainingText ?? "").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    HStack(spacing: 10) {
                        Button { play(item) } label: {
                            Label(item.progress != nil ? "Resume" : "Play", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                        Button { details(item) } label: {
                            Text(item.isEpisode ? "Go to show" : "Details")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(.top, 4)
                    if items.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(items.indices, id: \.self) { i in
                                Capsule()
                                    .fill(i == index % items.count ? Theme.accent : .white.opacity(0.35))
                                    .frame(width: i == index % items.count ? 18 : 6, height: 6)
                                    .onTapGesture { withAnimation(.easeInOut(duration: 0.5)) { index = i } }
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .id("text" + item.ratingKey)
                .transition(.opacity.combined(with: .offset(y: 10)))
            }
        }
        // fits the screen in landscape, roomy in portrait
        .containerRelativeFrame(.vertical) { h, _ in min(480, max(300, h * 0.86)) }
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            guard items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.5)) { index = (index + (v.translation.width < 0 ? 1 : items.count - 1)) % items.count }
            timer = Timer.publish(every: 9, on: .main, in: .common).autoconnect()
        })
        .onReceive(timer) { _ in
            guard items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.8)) { index = (index + 1) % items.count }
        }
        .task(id: items.map(\.ratingKey)) {
            for it in items { _ = await plex.show(for: it) }
        }
    }

    private func meta(_ it: PlexItem) -> String {
        if it.isEpisode { return [it.episodeCode, it.title].compactMap { $0 }.joined(separator: " · ") }
        return [it.year.map(String.init), it.contentRating, it.runtimeText].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Full-bleed background art fading into the page.
struct ArtBackdrop: View {
    let url: URL?
    var body: some View {
        ZStack {
            Theme.background
            // anchored to the top so faces and titles in the art aren't cropped off
            Color.clear.overlay(alignment: .top) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.5))) { phase in
                    if case .success(let img) = phase { img.resizable().scaledToFill() } else { Color.clear }
                }
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: Theme.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [Theme.background.opacity(0.75), .clear], startPoint: .leading, endPoint: .center)
        }
        .clipped()
    }
}

/// The show's title logo, or its name in big type when Plex has no logo.
struct TitleLogo: View {
    @EnvironmentObject var plex: PlexStore
    let item: PlexItem
    var maxWidth: CGFloat
    var maxHeight: CGFloat

    var body: some View {
        let name = item.isEpisode ? (item.grandparentTitle ?? item.title) : item.title
        if let url = plex.logoURL(for: item) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFit()
                } else {
                    Text(name).font(.system(size: 30, weight: .black)).lineLimit(2).opacity(0)
                }
            }
            .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .bottomLeading)
            .shadow(color: .black.opacity(0.5), radius: 8)
        } else {
            Text(name)
                .font(.system(size: 32, weight: .black))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: maxWidth * 1.3, alignment: .leading)
                .shadow(color: .black.opacity(0.6), radius: 8)
        }
    }
}
