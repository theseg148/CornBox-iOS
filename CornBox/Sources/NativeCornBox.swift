import SwiftUI
import AVFoundation
import WebKit
import UniformTypeIdentifiers

// MARK: - Models

struct Creator: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var handle: String?
    var bio: String?
    var photo: String?
}

struct MediaItem: Identifiable, Hashable {
    enum Kind: String { case video, image }
    let id: String
    let name: String
    let url: URL
    let kind: Kind
    var creatorId: String?
}

struct NativeState: Codable {
    var creators: [Creator] = []
    var assignments: [String: String] = [:]
    var liked: [String: Bool] = [:]
    var legacyRaw: [String: String] = [:]
    var migratedFromWeb = false
}

struct MigrationSnapshot: Codable {
    let creators: String?
    let assignments: String?
    let liked: String?
    let comments: String?
    let albums: String?
    let history: String?
    let activity: String?
}

enum AppTab: Hashable { case home, library, activity, creators }

// MARK: - Store

@MainActor
final class CornBoxStore: ObservableObject {
    @Published var media: [MediaItem] = []
    @Published var creators: [Creator] = []
    @Published var liked: [String: Bool] = [:]
    @Published var selectedTab: AppTab = .home
    @Published var currentMediaID: String?
    @Published var migrationFinished = false
    @Published var migrationMessage = "Checking existing CornBox data…"
    @Published var showFileImporter = false

    private(set) var state = NativeState()
    private let fm = FileManager.default

    let rootDirectory: URL
    let mediaDirectory: URL
    let stateURL: URL
    let backupURL: URL
    let legacyHTMLURL: URL

    init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootDirectory = base.appendingPathComponent("CornBox", isDirectory: true)
        mediaDirectory = rootDirectory.appendingPathComponent("media", isDirectory: true)
        stateURL = rootDirectory.appendingPathComponent("native-state.json")
        backupURL = rootDirectory.appendingPathComponent("migration-backup.json")
        legacyHTMLURL = rootDirectory.appendingPathComponent("app.html")

        try? fm.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        loadState()
        rescanMedia()
    }

    func loadState() {
        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode(NativeState.self, from: data) {
            state = saved
            creators = saved.creators
            liked = saved.liked
            migrationFinished = saved.migratedFromWeb
            if saved.migratedFromWeb { migrationMessage = "Existing CornBox data migrated." }
        }
    }

    func save() {
        state.creators = creators
        state.liked = liked
        guard let data = try? JSONEncoder.pretty.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    func rescanMedia() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: mediaDirectory,
                                                     includingPropertiesForKeys: Array(keys),
                                                     options: [.skipsHiddenFiles]) else {
            media = []
            return
        }

        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"]

        let sorted = urls.sorted {
            let a = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return a > b
        }

        media = sorted.compactMap { url in
            let ext = url.pathExtension.lowercased()
            let kind: MediaItem.Kind
            if videoExtensions.contains(ext) { kind = .video }
            else if imageExtensions.contains(ext) { kind = .image }
            else { return nil }

            let filename = url.lastPathComponent
            return MediaItem(id: filename,
                             name: filename,
                             url: url,
                             kind: kind,
                             creatorId: state.assignments[filename])
        }

        if currentMediaID == nil { currentMediaID = media.first?.id }
    }

    func creator(for item: MediaItem) -> Creator? {
        guard let id = item.creatorId else { return nil }
        return creators.first { $0.id == id }
    }

    func toggleLike(_ item: MediaItem) {
        liked[item.id] = !(liked[item.id] ?? false)
        save()
    }

    func shuffle() {
        media.shuffle()
        currentMediaID = media.first?.id
    }

    func markMigratedWithoutMetadata(_ message: String) {
        state.migratedFromWeb = true
        migrationFinished = true
        migrationMessage = message
        save()
    }

    func applyLegacySnapshot(_ json: String) {
        guard let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(MigrationSnapshot.self, from: data) else {
            markMigratedWithoutMetadata("Could not decode old metadata. Your media files are still intact.")
            return
        }

        // Raw migration backup. This gives us a recovery path even if a future native model changes.
        try? data.write(to: backupURL, options: .atomic)

        if let raw = snapshot.creators,
           let creatorData = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([Creator].self, from: creatorData) {
            creators = decoded
            state.creators = decoded
        }

        if let raw = snapshot.assignments,
           let assignmentData = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: assignmentData) {
            state.assignments = decoded
        }

        if let raw = snapshot.liked,
           let likeData = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: likeData) {
            liked = decoded
            state.liked = decoded
        }

        let rawPairs: [(String, String?)] = [
            ("creators", snapshot.creators),
            ("assignments", snapshot.assignments),
            ("liked", snapshot.liked),
            ("comments", snapshot.comments),
            ("albums", snapshot.albums),
            ("history", snapshot.history),
            ("activity", snapshot.activity)
        ]
        for (key, value) in rawPairs where value != nil { state.legacyRaw[key] = value! }

        state.migratedFromWeb = true
        migrationFinished = true
        save()
        rescanMedia()

        let assigned = media.filter { $0.creatorId != nil }.count
        migrationMessage = "Migrated \(creators.count) creators and \(assigned) media assignments."
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let destinationDirectory = mediaDirectory

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for source in urls {
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }

                var destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
                let originalStem = (source.lastPathComponent as NSString).deletingPathExtension
                let ext = (source.lastPathComponent as NSString).pathExtension
                var suffix = 2

                while fm.fileExists(atPath: destination.path) {
                    let name = ext.isEmpty ? "\(originalStem) \(suffix)" : "\(originalStem) \(suffix).\(ext)"
                    destination = destinationDirectory.appendingPathComponent(name)
                    suffix += 1
                }
                try? fm.copyItem(at: source, to: destination)
            }
            await MainActor.run { self.rescanMedia() }
        }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var store: CornBoxStore
    @StateObject private var pool = PlayerPool()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch store.selectedTab {
            case .home: NativeFeedView(pool: pool)
            case .library: LibraryView()
            case .activity: ActivityView()
            case .creators: CreatorsView()
            }

            VStack {
                Spacer()
                NativeTabBar()
            }
            .ignoresSafeArea(edges: .bottom)

            if !store.migrationFinished {
                LegacyMigrationBridge()
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)

                VStack {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(store.migrationMessage).font(.caption)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .fileImporter(isPresented: $store.showFileImporter,
                      allowedContentTypes: [.image, .movie],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.importFiles(urls) }
        }
    }
}

struct NativeTabBar: View {
    @EnvironmentObject var store: CornBoxStore

    var body: some View {
        HStack(spacing: 0) {
            tab(.home, "house.fill", "Home")
            tab(.library, "square.grid.2x2.fill", "Library")

            Button { store.showFileImporter = true } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(.white).frame(width: 46, height: 32)
                    Image(systemName: "plus").font(.system(size: 19, weight: .bold)).foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity)
            }

            tab(.activity, "clock.arrow.circlepath", "Activity")
            tab(.creators, "person.2.fill", "Creators")
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.black.opacity(0.96))
        .overlay(alignment: .top) { Divider().overlay(.gray.opacity(0.35)) }
    }

    private func tab(_ tab: AppTab, _ icon: String, _ title: String) -> some View {
        Button { store.selectedTab = tab } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(title).font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(store.selectedTab == tab ? .white : .gray)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Feed / AVPlayer

struct NativeFeedView: View {
    @EnvironmentObject var store: CornBoxStore
    @ObservedObject var pool: PlayerPool

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(store.media.enumerated()), id: \.element.id) { index, item in
                        FeedCell(item: item,
                                 isActive: item.id == store.currentMediaID,
                                 pool: pool)
                            .frame(width: geometry.size.width, height: geometry.size.height - 72)
                            .id(item.id)
                            .onAppear {
                                store.currentMediaID = item.id
                                pool.updateWindow(center: index, media: store.media)
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $store.currentMediaID)
            .background(.black)
            .overlay(alignment: .top) {
                HStack {
                    Button {
                        store.shuffle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    Spacer()
                    Text("For You").font(.headline.bold())
                    Spacer()
                    Color.clear.frame(width: 38, height: 38)
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
        }
        .onDisappear { pool.pauseAll() }
    }
}

struct FeedCell: View {
    @EnvironmentObject var store: CornBoxStore
    let item: MediaItem
    let isActive: Bool
    @ObservedObject var pool: PlayerPool

    var body: some View {
        ZStack {
            Color.black

            if item.kind == .video {
                if pool.activeIDs.contains(item.id), let player = pool.player(for: item) {
                    PlayerLayerView(player: player)
                        .onAppear { if isActive { player.play() } }
                        .onChange(of: isActive) { _, active in active ? player.play() : player.pause() }
                } else {
                    VideoThumbnailView(url: item.url).scaledToFit()
                }
            } else {
                LocalImageView(url: item.url).scaledToFit()
            }

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let creator = store.creator(for: item) {
                            HStack(spacing: 9) {
                                CreatorAvatar(creator: creator, size: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(creator.name).font(.subheadline.bold())
                                    if let handle = creator.handle, !handle.isEmpty {
                                        Text(handle).font(.caption).foregroundStyle(.white.opacity(0.72))
                                    }
                                }
                            }
                        } else {
                            Text("Unassigned").font(.subheadline.bold())
                        }
                        Text(item.name).font(.caption).foregroundStyle(.white.opacity(0.82)).lineLimit(2)
                    }
                    Spacer()
                    Button { store.toggleLike(item) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: (store.liked[item.id] ?? false) ? "heart.fill" : "heart")
                                .font(.system(size: 29))
                                .foregroundStyle((store.liked[item.id] ?? false) ? .orange : .white)
                            Text("Like").font(.system(size: 9, weight: .semibold))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .clipped()
    }
}

@MainActor
final class PlayerPool: ObservableObject {
    @Published private(set) var activeIDs: Set<String> = []
    private var players: [String: AVPlayer] = [:]

    func updateWindow(center: Int, media: [MediaItem]) {
        guard !media.isEmpty else { activeIDs = []; pauseAll(); return }

        let lower = max(0, center - 1)
        let upper = min(media.count - 1, center + 2)
        let wanted = Set(media[lower...upper].filter { $0.kind == .video }.map(\.id))

        let stale = players.keys.filter { !wanted.contains($0) }
        for id in stale {
            players[id]?.pause()
            players[id]?.replaceCurrentItem(with: nil)
            players.removeValue(forKey: id)
        }
        activeIDs = wanted
    }

    func player(for item: MediaItem) -> AVPlayer? {
        guard item.kind == .video, activeIDs.contains(item.id) else { return nil }
        if let existing = players[item.id], existing.currentItem != nil { return existing }

        let asset = AVURLAsset(url: item.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 5
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        players[item.id] = player
        return player
    }

    func pauseAll() { players.values.forEach { $0.pause() } }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ uiView: PlayerUIView, context: Context) { uiView.playerLayer.player = player }
}

final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject var store: CornBoxStore
    @State private var search = ""

    private var filtered: [MediaItem] {
        guard !search.isEmpty else { return store.media }
        return store.media.filter { item in
            if item.name.localizedCaseInsensitiveContains(search) { return true }
            guard let creator = store.creator(for: item) else { return false }
            return creator.name.localizedCaseInsensitiveContains(search) ||
                   (creator.handle?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(filtered) { item in
                        LibraryTile(item: item).aspectRatio(0.72, contentMode: .fit)
                    }
                }
            }
            .background(.black)
            .navigationTitle("Library")
            .searchable(text: $search, prompt: "Search media or creator")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.shuffle()
                        store.selectedTab = .home
                    } label: { Image(systemName: "shuffle") }
                }
            }
            .padding(.bottom, 72)
        }
    }
}

struct LibraryTile: View {
    @EnvironmentObject var store: CornBoxStore
    let item: MediaItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color(white: 0.08))
            if item.kind == .video { VideoThumbnailView(url: item.url).scaledToFill().clipped() }
            else { LocalImageView(url: item.url).scaledToFill().clipped() }

            Text(store.creator(for: item)?.name ?? "Unassigned")
                .font(.system(size: 9, weight: .bold))
                .lineLimit(1)
                .padding(5)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                .padding(5)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.currentMediaID = item.id
            store.selectedTab = .home
        }
    }
}

// MARK: - Creators / Activity

struct CreatorsView: View {
    @EnvironmentObject var store: CornBoxStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Media", value: "\(store.media.count)")
                    LabeledContent("Creators", value: "\(store.creators.count)")
                    LabeledContent("Assigned", value: "\(store.media.filter { $0.creatorId != nil }.count)")
                }
                Section("Creator Profiles") {
                    if store.creators.isEmpty { Text("No creator profiles were migrated.").foregroundStyle(.secondary) }
                    ForEach(store.creators) { creator in
                        HStack(spacing: 12) {
                            CreatorAvatar(creator: creator, size: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(creator.name).font(.headline)
                                if let handle = creator.handle { Text(handle).font(.caption).foregroundStyle(.secondary) }
                                Text("\(store.media.filter { $0.creatorId == creator.id }.count) media")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("Migration") {
                    Text(store.migrationMessage).font(.caption)
                    if FileManager.default.fileExists(atPath: store.backupURL.path) {
                        Label("Migration backup saved", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Creators")
            .padding(.bottom, 60)
        }
    }
}

struct ActivityView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Native Activity",
                                   systemImage: "clock.arrow.circlepath",
                                   description: Text("Old activity, comments and albums are preserved in the migration backup. Their native UI comes next."))
                .navigationTitle("Activity")
                .padding(.bottom, 72)
        }
    }
}

// MARK: - Images / thumbnails

struct CreatorAvatar: View {
    let creator: Creator
    let size: CGFloat

    var body: some View {
        Group {
            if let photo = creator.photo, let image = decodeDataURLImage(photo) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color(white: 0.16))
                    Text(String(creator.name.prefix(1)).uppercased()).font(.system(size: size * 0.38, weight: .bold))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct LocalImageView: View {
    let url: URL
    var body: some View {
        if let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable() }
        else { ZStack { Color(white: 0.08); Image(systemName: "photo").foregroundStyle(.secondary) } }
    }
}

struct VideoThumbnailView: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable() }
            else { ZStack { Color(white: 0.06); Image(systemName: "play.fill").foregroundStyle(.white.opacity(0.65)) } }
        }
        .task(id: url) { if image == nil { image = await ThumbnailService.shared.thumbnail(for: url) } }
    }
}

actor ThumbnailService {
    static let shared = ThumbnailService()
    private var cache: [String: UIImage] = [:]

    func thumbnail(for url: URL) -> UIImage? {
        if let cached = cache[url.path] { return cached }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 640)
        guard let cg = try? generator.copyCGImage(at: CMTime(seconds: 0.15, preferredTimescale: 600), actualTime: nil) else { return nil }
        let image = UIImage(cgImage: cg)
        cache[url.path] = image
        return image
    }
}

func decodeDataURLImage(_ string: String) -> UIImage? {
    guard let comma = string.firstIndex(of: ",") else { return nil }
    let payload = String(string[string.index(after: comma)...])
    guard let data = Data(base64Encoded: payload) else { return nil }
    return UIImage(data: data)
}

// MARK: - One-time migration bridge

struct LegacyMigrationBridge: UIViewRepresentable {
    @EnvironmentObject var store: CornBoxStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        let fm = FileManager.default
        if fm.fileExists(atPath: store.legacyHTMLURL.path) {
            webView.loadFileURL(store.legacyHTMLURL, allowingReadAccessTo: store.rootDirectory)
        } else if let bundled = Bundle.main.url(forResource: "app", withExtension: "html") {
            do {
                try fm.createDirectory(at: store.rootDirectory, withIntermediateDirectories: true)
                try fm.copyItem(at: bundled, to: store.legacyHTMLURL)
                webView.loadFileURL(store.legacyHTMLURL, allowingReadAccessTo: store.rootDirectory)
            } catch {
                store.markMigratedWithoutMetadata("No old metadata page was available. Existing media is still intact.")
            }
        } else {
            store.markMigratedWithoutMetadata("No old metadata page was available. Existing media is still intact.")
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let store: CornBoxStore
        var attempted = false
        init(store: CornBoxStore) { self.store = store }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !attempted else { return }
            attempted = true
            let js = """
            JSON.stringify({
              creators: localStorage.getItem('cb_creators_v2'),
              assignments: localStorage.getItem('cb_creator_assignments_v2'),
              liked: localStorage.getItem('cb_likes_v2'),
              comments: localStorage.getItem('cb_comments_v2'),
              albums: localStorage.getItem('cb_albums_v2'),
              history: localStorage.getItem('cb_history_v2'),
              activity: localStorage.getItem('cb_activity_v2')
            })
            """
            webView.evaluateJavaScript(js) { result, _ in
                Task { @MainActor in
                    if let json = result as? String { self.store.applyLegacySnapshot(json) }
                    else { self.store.markMigratedWithoutMetadata("Old metadata was unavailable. Existing media is still intact.") }
                }
            }
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
