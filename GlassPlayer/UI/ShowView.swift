import SwiftUI

struct ShowView: View {
    @EnvironmentObject var plex: PlexStore
    let show: PlexItem
    var play: (PlayRequest) -> Void

    @State private var seasons: [PlexItem] = []
    @State private var season: PlexItem?
    @State private var episodes: [PlexItem] = []
    @State private var starting: String?
    @State private var expanded = false

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if seasons.count > 1 { seasonPicker }
                    LazyVStack(spacing: 12) {
                        ForEach(episodes) { ep in
                            EpisodeRow(item: ep, busy: starting == ep.ratingKey)
                                .onTapGesture { start(ep) }
                                .contextMenu {
                                    Button { start(ep) } label: { Label("Play", systemImage: "play.fill") }
                                    Button { start(ep, fromStart: true) } label: { Label("Play from beginning", systemImage: "arrow.counterclockwise") }
                                    Button {
                                        Task {
                                            await plex.setWatched(ep, !ep.watched)
                                            await loadEpisodes()
                                        }
                                    } label: {
                                        Label(ep.watched ? "Mark unwatched" : "Mark watched", systemImage: ep.watched ? "eye.slash" : "eye")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 30)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            _ = await plex.show(for: show)
            await load()
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            ArtBackdrop(url: plex.imageURL(full.art ?? show.art, width: 1280, height: 720))
            VStack(alignment: .leading, spacing: 10) {
                TitleLogo(item: full, maxWidth: 260, maxHeight: 100)
                Text(metaLine).font(.subheadline.weight(.semibold))
                if let summary = full.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(expanded ? nil : 3)
                        .onTapGesture { withAnimation { expanded.toggle() } }
                }
                if let next = upNext {
                    Button { start(next) } label: {
                        Label(next.progress != nil ? "Resume \(next.episodeCode ?? "")" : "Play \(next.episodeCode ?? "")",
                              systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .padding(.top, 4)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .frame(minHeight: 430)
    }

    private var full: PlexItem { plex.shows[show.ratingKey] ?? show }

    private var metaLine: String {
        var parts: [String] = []
        if let y = full.year { parts.append(String(y)) }
        if let r = full.contentRating { parts.append(r) }
        if seasons.count > 0 { parts.append("\(seasons.count) season\(seasons.count == 1 ? "" : "s")") }
        if let a = full.audienceRating, a > 0 { parts.append(String(format: "★ %.1f", a)) }
        return parts.joined(separator: " · ")
    }

    private var seasonPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(seasons) { s in
                        let selected = s.ratingKey == season?.ratingKey
                        Button {
                            season = s
                            Task { await loadEpisodes() }
                        } label: {
                            Text(s.title).font(.subheadline.weight(selected ? .bold : .medium))
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.glass)
                        .tint(selected ? Theme.accent : nil)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// First in-progress or unwatched episode of the selected season.
    private var upNext: PlexItem? {
        episodes.first(where: { $0.progress != nil }) ?? episodes.first(where: { !$0.watched })
    }

    private func load() async {
        guard let s = plex.server else { return }
        seasons = (try? await plex.api.children(s, of: show.ratingKey)) ?? []
        if season == nil {
            // Open on the first season that isn't fully watched.
            season = seasons.first(where: { !$0.watched && ($0.index ?? 1) > 0 }) ?? seasons.first
        }
        await loadEpisodes()
    }

    private func loadEpisodes() async {
        guard let s = plex.server, let season else { return }
        episodes = (try? await plex.api.children(s, of: season.ratingKey)) ?? []
    }

    private func start(_ ep: PlexItem, fromStart: Bool = false) {
        starting = ep.ratingKey
        Task {
            defer { starting = nil }
            if let req = await plex.playRequest(for: ep, fromStart: fromStart) { play(req) }
        }
    }
}

struct EpisodeRow: View {
    @EnvironmentObject var plex: PlexStore
    let item: PlexItem
    var busy = false

    var body: some View {
        HStack(spacing: 14) {
            PosterImage(url: plex.imageURL(item.thumb, width: 200, height: 112), corner: 12)
                .frame(width: 150, height: 84)
                .overlay {
                    if busy { ProgressView().tint(.white) }
                }
                .overlay(alignment: .bottom) {
                    if let p = item.progress { ProgressLine(value: p).padding(6) }
                }
                .overlay(alignment: .topTrailing) {
                    if item.watched { WatchedBadge().scaleEffect(0.8).padding(4) }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.episodeCode ?? "").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let d = item.duration {
                    Text("\(d / 60000) min").font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .foregroundStyle(.white)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .contentShape(Rectangle())
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case title, added, released, watched, unwatched
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: return "Title"
        case .added: return "Recently added"
        case .released: return "Release date"
        case .watched: return "Recently watched"
        case .unwatched: return "Unwatched first"
        }
    }
    func apply(_ items: [PlexItem]) -> [PlexItem] {
        switch self {
        case .title: return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .added: return items.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        case .released: return items.sorted { ($0.originallyAvailableAt ?? String($0.year ?? 0)) > ($1.originallyAvailableAt ?? String($1.year ?? 0)) }
        case .watched: return items.sorted { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }
        case .unwatched: return items.sorted { a, b in
            if a.watched != b.watched { return !a.watched }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        }
    }
}

struct SectionView: View {
    @EnvironmentObject var plex: PlexStore
    let section: PlexSection
    var play: (PlayRequest) -> Void

    @State private var items: [PlexItem] = []
    @State private var loading = true
    @AppStorage("sectionSorts") private var sortsJSON = "{}"

    private var sort: LibrarySort {
        let d = (try? JSONDecoder().decode([String: String].self, from: Data(sortsJSON.utf8))) ?? [:]
        return LibrarySort(rawValue: d[section.key] ?? "") ?? .title
    }

    private func setSort(_ s: LibrarySort) {
        var d = (try? JSONDecoder().decode([String: String].self, from: Data(sortsJSON.utf8))) ?? [:]
        d[section.key] = s.rawValue
        sortsJSON = String(data: (try? JSONEncoder().encode(d)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 14)], spacing: 18) {
                    ForEach(sort.apply(items)) { item in
                        if item.type == "show" {
                            NavigationLink(value: Route.show(item)) { PosterCard(item: item, width: nil) }
                                .buttonStyle(.plain)
                        } else {
                            PosterCard(item: item, width: nil)
                                .onTapGesture {
                                    Task { if let r = await plex.playRequest(for: item) { play(r) } }
                                }
                        }
                    }
                }
                .padding()
            }
            if loading { ProgressView().tint(.white).controlSize(.large) }
        }
        .navigationTitle(section.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: Binding(get: { sort }, set: { setSort($0) })) {
                        ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .task {
            guard let s = plex.server else { return }
            items = (try? await plex.api.all(s, section: section.key)) ?? []
            loading = false
        }
    }
}
