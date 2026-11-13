import SwiftUI
import UniformTypeIdentifiers

enum Route: Hashable {
    case show(PlexItem)
    case section(PlexSection)
}

struct HomeView: View {
    @EnvironmentObject var plex: PlexStore
    var play: (PlayRequest) -> Void

    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var results: [PlexItem] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var importing = false
    @State private var settings = false
    @State private var localFiles: [URL] = []
    @State private var starting: String?
    @State private var editing = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Backdrop()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        if !query.isEmpty {
                            searchResults.padding(.top, 12)
                        } else {
                            if !heroItems.isEmpty {
                                HeroCarousel(items: heroItems, play: { start($0) }, details: { details($0) })
                                    .padding(.bottom, -14)
                            }
                            homeRows
                        }
                    }
                    .padding(.bottom, 12)
                }
                .ignoresSafeArea(edges: query.isEmpty ? .top : [])
                .refreshable { await plex.refreshHome() }

                if plex.loading && plex.continueWatching.isEmpty && plex.sections.isEmpty {
                    ProgressView().tint(.white).controlSize(.large)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .searchable(text: $query, prompt: "Shows, movies, episodes")
            .onChange(of: query) { _, q in runSearch(q) }
            .toolbar {
                // top left: jump to any library
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Section("Libraries") {
                            ForEach(plex.orderedSections) { sec in
                                Button { path.append(Route.section(sec)) } label: {
                                    Label(sec.title, systemImage: sec.type == "movie" ? "film" : "tv")
                                }
                            }
                        }
                        Divider()
                        Button { editing = true } label: { Label("Edit home", systemImage: "list.bullet.indent") }
                        Button { settings = true } label: { Label("Settings", systemImage: "gearshape") }
                    } label: {
                        Label("Libraries", systemImage: "line.3.horizontal")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { editing = true } label: { Image(systemName: "list.bullet.indent") }
                        .accessibilityLabel("Edit home")
                    Button { importing = true } label: { Image(systemName: "folder") }
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .show(let item): ShowView(show: item, play: play)
                case .section(let s): SectionView(section: s, play: play)
                }
            }
        }
        .task {
            localFiles = LocalFiles.documents()
            if plex.continueWatching.isEmpty { await plex.refreshHome() }
        }
        .sheet(isPresented: $settings) { SettingsView().environmentObject(plex) }
        .sheet(isPresented: $editing) { EditHomeView().environmentObject(plex) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .audiovisualContent, .data]) { result in
            if case .success(let url) = result { play(LocalFiles.request(for: url)) }
        }
    }

    // MARK: rows

    @ViewBuilder private var homeRows: some View {
        if let err = plex.homeError {
            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.accent)
                Text(err).font(.subheadline)
                Spacer()
                Button("Retry") { Task { await plex.pickServer() } }.buttonStyle(.glass)
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(.horizontal)
        }

        if !plex.continueWatching.isEmpty {
            RowHeader(title: "Continue watching")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(plex.continueWatching) { item in
                        WideCard(item: item, busy: starting == item.ratingKey)
                            .onTapGesture { start(item) }
                            .contextMenu { itemMenu(item) }
                    }
                }
                .padding(.horizontal)
            }
        }

        ForEach(plex.orderedSections) { sec in
            if let items = plex.recent[sec.key], !items.isEmpty {
                NavigationLink(value: Route.section(sec)) {
                    RowHeader(title: sec.title, chevron: true)
                }
                .buttonStyle(.plain)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            PosterCard(item: item, width: 124)
                                .onTapGesture { open(item) }
                                .contextMenu { itemMenu(item) }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }

        if !localFiles.isEmpty {
            RowHeader(title: "On this iPhone")
            VStack(spacing: 0) {
                ForEach(localFiles, id: \.self) { url in
                    Button { play(LocalFiles.request(for: url)) } label: {
                        HStack {
                            Image(systemName: "film").foregroundStyle(Theme.accent)
                            Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                            Spacer()
                            Image(systemName: "play.fill").font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        .padding(.vertical, 12).padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(.horizontal)
        }
    }

    @ViewBuilder private var searchResults: some View {
        if results.isEmpty {
            Text("No matches").foregroundStyle(Theme.secondaryText).padding()
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 14)], spacing: 18) {
                ForEach(results) { item in
                    PosterCard(item: item, width: nil)
                        .onTapGesture { open(item) }
                }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder private func itemMenu(_ item: PlexItem) -> some View {
        if !item.isShowLike {
            Button { start(item) } label: { Label("Play", systemImage: "play.fill") }
            Button { start(item, fromStart: true) } label: { Label("Play from beginning", systemImage: "arrow.counterclockwise") }
        }
        if item.isEpisode, let show = item.grandparentRatingKey {
            Button { openShow(ratingKey: show, title: item.grandparentTitle ?? "") } label: {
                Label("Go to show", systemImage: "tv")
            }
        }
        Button { Task { await plex.setWatched(item, !item.watched) } } label: {
            Label(item.watched ? "Mark unwatched" : "Mark watched", systemImage: item.watched ? "eye.slash" : "eye")
        }
    }

    // MARK: actions

    private var heroItems: [PlexItem] {
        let cw = Array(plex.continueWatching.prefix(6))
        if !cw.isEmpty { return cw }
        return plex.orderedSections.compactMap { plex.recent[$0.key]?.first }.prefix(6).map { $0 }
    }

    private func details(_ item: PlexItem) {
        if item.isEpisode, let show = item.grandparentRatingKey { openShow(ratingKey: show, title: item.grandparentTitle ?? "") }
        else if item.type == "show" { path.append(Route.show(item)) }
        else { start(item) }
    }

    private func open(_ item: PlexItem) {
        if item.type == "show" { path.append(Route.show(item)) }
        else if item.type == "season", let show = item.parentRatingKey { openShow(ratingKey: show, title: item.parentTitle ?? "") }
        else { start(item) }
    }

    private func openShow(ratingKey: String, title: String) {
        Task {
            guard let s = plex.server, let show = try? await plex.api.metadata(s, ratingKey) else { return }
            path.append(Route.show(show))
        }
    }

    private func start(_ item: PlexItem, fromStart: Bool = false) {
        starting = item.ratingKey
        Task {
            defer { starting = nil }
            if let req = await plex.playRequest(for: item, fromStart: fromStart) { play(req) }
        }
    }

    private func runSearch(_ q: String) {
        searchTask?.cancel()
        let text = q.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            guard let s = plex.server else { return }
            let r = (try? await plex.api.search(s, text)) ?? []
            if !Task.isCancelled { results = r }
        }
    }
}

struct RowHeader: View {
    let title: String
    var chevron = false
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.title3.weight(.bold))
            if chevron { Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(Theme.secondaryText) }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.bottom, -16)
    }
}

/// Portrait poster card (shows, movies).
struct PosterCard: View {
    @EnvironmentObject var plex: PlexStore
    let item: PlexItem
    let width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: plex.imageURL(item.posterPath, width: 240, height: 360))
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(width: width)
                .overlay(alignment: .topTrailing) {
                    if item.watched { WatchedBadge().padding(6) }
                    else if let u = unwatchedCount { CountBadge(n: u).padding(6) }
                }
                .overlay(alignment: .bottom) {
                    if let p = item.progress { ProgressLine(value: p).padding(8) }
                }
            Text(item.displayTitle).font(.footnote.weight(.semibold)).lineLimit(1)
            if let sub = item.displaySubtitle {
                Text(sub).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
        }
        .frame(width: width)
        .foregroundStyle(.white)
        .contentShape(Rectangle())
    }

    private var unwatchedCount: Int? {
        guard item.type == "show", let l = item.leafCount, let v = item.viewedLeafCount, l > v, v > 0 else { return nil }
        return l - v
    }
}

struct CountBadge: View {
    let n: Int
    var body: some View {
        Text("\(n)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .glassEffect(.regular.tint(Theme.accent.opacity(0.7)), in: .capsule)
    }
}

/// Landscape card for Continue watching, with progress.
struct WideCard: View {
    @EnvironmentObject var plex: PlexStore
    let item: PlexItem
    var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PosterImage(url: plex.imageURL(item.stillPath, width: 300, height: 170), corner: 16)
                .frame(width: 260, height: 146)
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    if let logo = plex.logoURL(for: item) {
                        AsyncImage(url: logo) { ph in
                            if case .success(let img) = ph { img.resizable().scaledToFit() } else { Color.clear }
                        }
                        .frame(maxWidth: 110, maxHeight: 38, alignment: .bottomLeading)
                        .padding(.leading, 12)
                        .padding(.bottom, 16)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                    }
                }
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .glassEffect(.regular, in: .circle)
                        .opacity(busy ? 0 : 1)
                    if busy { ProgressView().tint(.white) }
                }
                .overlay(alignment: .bottom) {
                    if let p = item.progress { ProgressLine(value: p).padding(10) }
                }
            Text(item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
            if let sub = item.displaySubtitle {
                Text(sub).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
        }
        .frame(width: 260)
        .task { _ = await plex.show(for: item) }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
    }
}

/// Reorder (drag) and show/hide the library rows on the home page.
struct EditHomeView: View {
    @EnvironmentObject var plex: PlexStore
    @Environment(\.dismiss) private var dismiss
    @State private var keys: [String] = []
    @State private var hidden: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(keys, id: \.self) { key in
                        if let sec = plex.sections.first(where: { $0.key == key }) {
                            HStack(spacing: 12) {
                                Image(systemName: sec.type == "movie" ? "film" : "tv")
                                    .foregroundStyle(hidden.contains(key) ? Theme.secondaryText : Theme.accent)
                                    .frame(width: 24)
                                Text(sec.title)
                                    .foregroundStyle(hidden.contains(key) ? Theme.secondaryText : .white)
                                Spacer()
                                Button {
                                    if hidden.contains(key) { hidden.remove(key) } else { hidden.insert(key) }
                                } label: {
                                    Image(systemName: hidden.contains(key) ? "eye.slash" : "eye")
                                        .foregroundStyle(hidden.contains(key) ? Theme.secondaryText : .white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .onMove { from, to in keys.move(fromOffsets: from, toOffset: to) }
                } footer: {
                    Text("Drag to reorder. Tap the eye to hide a library from the home page.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        plex.saveSectionOrder(keys, hidden: hidden)
                        dismiss()
                    }
                }
            }
            .onAppear {
                keys = plex.sortedSections.map(\.key)
                hidden = plex.hiddenSections
            }
        }
    }
}
