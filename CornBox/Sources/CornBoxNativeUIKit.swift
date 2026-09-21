import SwiftUI
import UIKit
import AVFoundation
import WebKit
import UniformTypeIdentifiers
import PhotosUI
import ImageIO

struct RootView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        CornBoxTabController(store: .shared)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct CBCreator: Codable, Hashable {
    var id: String
    var name: String
    var handle: String
    var bio: String
    var photo: String?
}

struct CBMedia: Hashable {
    enum Kind: String {
        case video
        case image
    }

    let id: String
    let name: String
    let url: URL
    let kind: Kind
    var creatorID: String?
}

struct CBState: Codable {
    var creators: [CBCreator] = []
    var assignments: [String: String] = [:]
    var liked: [String: Bool] = [:]
    var commentsRaw: String?
    var albumsRaw: String?
    var historyRaw: String?
    var activityRaw: String?
    var migrated = false
}

struct LegacySnapshot: Codable {
    let creators: String?
    let assignments: String?
    let liked: String?
    let comments: String?
    let albums: String?
    let history: String?
    let activity: String?
}

struct CBActivity {
    let title: String
    let detail: String
    let type: String
    let timestamp: Double
}

final class CornBoxStore {
    static let shared = CornBoxStore()

    private let fm = FileManager.default
    let rootDirectory: URL
    let mediaDirectory: URL
    let stateURL: URL
    let backupURL: URL
    let legacyHTMLURL: URL

    private(set) var state = CBState()
    private(set) var media: [CBMedia] = []
    var onChange: (() -> Void)?

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootDirectory = base.appendingPathComponent("CornBox", isDirectory: true)
        mediaDirectory = rootDirectory.appendingPathComponent("media", isDirectory: true)
        stateURL = rootDirectory.appendingPathComponent("native-state-v3.json")
        backupURL = rootDirectory.appendingPathComponent("migration-backup-v3.json")
        legacyHTMLURL = rootDirectory.appendingPathComponent("app.html")

        try? fm.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        loadState()
        scanMedia(notify: false)
    }

    var creators: [CBCreator] {
        state.creators
    }

    func creator(for item: CBMedia) -> CBCreator? {
        guard let id = item.creatorID else { return nil }
        return state.creators.first { $0.id == id }
    }

    func creatorCount(_ id: String) -> Int {
        media.filter { $0.creatorID == id }.count
    }

    func isLiked(_ id: String) -> Bool {
        state.liked[id] == true
    }

    func toggleLike(_ id: String) {
        state.liked[id] = !(state.liked[id] ?? false)
        persist()
    }

    func setCreator(_ creatorID: String?, for mediaID: String) {
        if let creatorID {
            state.assignments[mediaID] = creatorID
        } else {
            state.assignments.removeValue(forKey: mediaID)
        }
        scanMedia(notify: false)
        persist()
    }

    func saveCreator(_ creator: CBCreator) {
        if let index = state.creators.firstIndex(where: { $0.id == creator.id }) {
            state.creators[index] = creator
        } else {
            state.creators.append(creator)
        }
        persist()
    }

    func deleteCreator(_ id: String) {
        state.creators.removeAll { $0.id == id }
        state.assignments = state.assignments.filter { $0.value != id }
        scanMedia(notify: false)
        persist()
    }

    func deleteMedia(_ id: String) {
        guard let item = media.first(where: { $0.id == id }) else { return }
        try? fm.removeItem(at: item.url)
        state.assignments.removeValue(forKey: id)
        state.liked.removeValue(forKey: id)
        scanMedia(notify: false)
        persist()
    }

    func scanMedia(notify: Bool = true) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(
            at: mediaDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"]

        let sorted = urls.sorted {
            let a = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return a > b
        }

        media = sorted.compactMap { url in
            let ext = url.pathExtension.lowercased()
            let kind: CBMedia.Kind

            if videoExtensions.contains(ext) {
                kind = .video
            } else if imageExtensions.contains(ext) {
                kind = .image
            } else {
                return nil
            }

            let id = url.lastPathComponent
            return CBMedia(
                id: id,
                name: id,
                url: url,
                kind: kind,
                creatorID: state.assignments[id]
            )
        }

        if notify {
            onChange?()
        }
    }

    func importFiles(_ urls: [URL], completion: @escaping () -> Void) {
        guard !urls.isEmpty else {
            completion()
            return
        }

        let destinationDirectory = mediaDirectory

        DispatchQueue.global(qos: .userInitiated).async {
            for source in urls {
                autoreleasepool {
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer {
                        if scoped {
                            source.stopAccessingSecurityScopedResource()
                        }
                    }

                    let original = source.lastPathComponent
                    let stem = (original as NSString).deletingPathExtension
                    let ext = (original as NSString).pathExtension
                    var destination = destinationDirectory.appendingPathComponent(original)
                    var suffix = 2

                    while FileManager.default.fileExists(atPath: destination.path) {
                        let name = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
                        destination = destinationDirectory.appendingPathComponent(name)
                        suffix += 1
                    }

                    try? FileManager.default.copyItem(at: source, to: destination)
                }
            }

            DispatchQueue.main.async {
                self.scanMedia()
                completion()
            }
        }
    }

    func activities() -> [CBActivity] {
        guard let raw = state.activityRaw,
              let data = raw.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return rows.map { row in
            CBActivity(
                title: row["title"] as? String ?? row["type"] as? String ?? "Activity",
                detail: row["detail"] as? String ?? "",
                type: row["type"] as? String ?? "activity",
                timestamp: (row["ts"] as? NSNumber)?.doubleValue ?? 0
            )
        }.sorted { $0.timestamp > $1.timestamp }
    }

    func migrate(from webView: WKWebView, completion: @escaping (String) -> Void) {
        guard !state.migrated else {
            completion("Migration already complete")
            return
        }

        let script = """
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

        webView.evaluateJavaScript(script) { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(LegacySnapshot.self, from: data) else {
                self.state.migrated = true
                self.saveState()
                completion("Media preserved; no legacy metadata found")
                return
            }

            try? data.write(to: self.backupURL, options: .atomic)

            if let raw = snapshot.creators,
               let creatorData = raw.data(using: .utf8),
               let rows = try? JSONSerialization.jsonObject(with: creatorData) as? [[String: Any]] {
                self.state.creators = rows.compactMap { row in
                    guard let id = row["id"] as? String,
                          let name = row["name"] as? String else {
                        return nil
                    }

                    return CBCreator(
                        id: id,
                        name: name,
                        handle: row["handle"] as? String ?? "",
                        bio: row["bio"] as? String ?? "",
                        photo: row["photo"] as? String
                    )
                }
            }

            if let raw = snapshot.assignments,
               let assignmentData = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: String].self, from: assignmentData) {
                self.state.assignments = decoded
            }

            if let raw = snapshot.liked,
               let likeData = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: Bool].self, from: likeData) {
                self.state.liked = decoded
            }

            self.state.commentsRaw = snapshot.comments
            self.state.albumsRaw = snapshot.albums
            self.state.historyRaw = snapshot.history
            self.state.activityRaw = snapshot.activity
            self.state.migrated = true
            self.saveState()
            self.scanMedia(notify: false)
            self.onChange?()
            completion("Migrated \(self.state.creators.count) creators")
        }
    }

    func fileExists(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
    }

    func copyLegacyHTMLIfNeeded(from bundleURL: URL) throws {
        if !fm.fileExists(atPath: legacyHTMLURL.path) {
            try fm.copyItem(at: bundleURL, to: legacyHTMLURL)
        }
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder().decode(CBState.self, from: data) else {
            return
        }
        state = decoded
    }

    private func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func persist() {
        saveState()
        onChange?()
    }
}

final class CornBoxTabController: UITabBarController, UITabBarControllerDelegate, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    private let store: CornBoxStore
    private let feed: FeedViewController
    private let library: LibraryViewController
    private let activity: ActivityViewController
    private let creators: CreatorsViewController
    private let addPlaceholder = UIViewController()
    private var migrationController: MigrationController?

    init(store: CornBoxStore) {
        self.store = store
        feed = FeedViewController(store: store)
        library = LibraryViewController(store: store)
        activity = ActivityViewController(store: store)
        creators = CreatorsViewController(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        view.backgroundColor = .black

        let homeNav = UINavigationController(rootViewController: feed)
        homeNav.setNavigationBarHidden(true, animated: false)
        let libraryNav = UINavigationController(rootViewController: library)
        let activityNav = UINavigationController(rootViewController: activity)
        let creatorsNav = UINavigationController(rootViewController: creators)

        homeNav.tabBarItem = UITabBarItem(title: "Home", image: UIImage(systemName: "house.fill"), tag: 0)
        libraryNav.tabBarItem = UITabBarItem(title: "Library", image: UIImage(systemName: "square.grid.2x2.fill"), tag: 1)
        addPlaceholder.tabBarItem = UITabBarItem(title: "Add", image: UIImage(systemName: "plus.square.fill"), tag: 2)
        activityNav.tabBarItem = UITabBarItem(title: "Activity", image: UIImage(systemName: "clock.arrow.circlepath"), tag: 3)
        creatorsNav.tabBarItem = UITabBarItem(title: "Creators", image: UIImage(systemName: "person.2.fill"), tag: 4)

        setViewControllers([homeNav, libraryNav, addPlaceholder, activityNav, creatorsNav], animated: false)

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .black
        appearance.stackedLayoutAppearance.normal.iconColor = .systemGray
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.systemGray]
        appearance.stackedLayoutAppearance.selected.iconColor = .white
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.white]
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = .white
        tabBar.unselectedItemTintColor = .systemGray

        store.onChange = { [weak self] in
            self?.feed.reloadPreservingPosition()
            self?.library.reloadData()
            self?.activity.reloadData()
            self?.creators.reloadData()
        }

        if !store.state.migrated {
            beginMigration()
        }
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if viewController === addPlaceholder {
            presentAddMenu()
            return false
        }
        return true
    }

    private func presentAddMenu() {
        let sheet = UIAlertController(title: "Add media", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Photos", style: .default) { _ in
            self.presentPhotoPicker()
        })
        sheet.addAction(UIAlertAction(title: "Files", style: .default) { _ in
            self.presentFilePicker()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = sheet.popoverPresentationController {
            popover.sourceView = tabBar
            popover.sourceRect = tabBar.bounds
        }

        present(sheet, animated: true)
    }

    private func presentFilePicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image, .movie], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentPhotoPicker() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        importURLs(urls)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }

        let group = DispatchGroup()
        let lock = NSLock()
        var temporaryURLs: [URL] = []

        for result in results {
            let provider = result.itemProvider
            let type: UTType?

            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                type = .movie
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                type = .image
            } else {
                type = nil
            }

            guard let type else { continue }
            group.enter()

            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                defer { group.leave() }
                guard let url else { return }

                let ext = url.pathExtension.isEmpty ? (type.conforms(to: .movie) ? "mov" : "jpg") : url.pathExtension
                let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseName = (suggested?.isEmpty == false ? suggested! : UUID().uuidString)
                let fileName = (baseName as NSString).pathExtension.isEmpty ? "\(baseName).\(ext)" : baseName
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + fileName)

                do {
                    try FileManager.default.copyItem(at: url, to: temporary)
                    lock.lock()
                    temporaryURLs.append(temporary)
                    lock.unlock()
                } catch {}
            }
        }

        group.notify(queue: .main) {
            self.importURLs(temporaryURLs)
        }
    }

    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let alert = UIAlertController(title: "Importing", message: "Adding \(urls.count) item\(urls.count == 1 ? "" : "s")…", preferredStyle: .alert)
        present(alert, animated: true)

        store.importFiles(urls) {
            alert.dismiss(animated: true)
        }
    }

    private func beginMigration() {
        let controller = MigrationController(store: store) { [weak self] _ in
            self?.migrationController = nil
        }
        migrationController = controller
        addChild(controller)
        controller.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        controller.view.alpha = 0.001
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
    }

    func showFeedItem(_ id: String) {
        feed.open(mediaID: id)
        selectedIndex = 0
    }

    func shuffleFeed() {
        feed.shuffleNow()
        selectedIndex = 0
    }
}

final class FeedViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    private let store: CornBoxStore
    private let layout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var items: [CBMedia]
    private var currentID: String?

    init(store: CornBoxStore) {
        self.store = store
        items = store.media
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        collectionView.backgroundColor = .black
        collectionView.isPagingEnabled = true
        collectionView.alwaysBounceVertical = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FeedCell.self, forCellWithReuseIdentifier: FeedCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        let title = UILabel()
        title.text = "For You"
        title.textColor = .white
        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)

        let shuffle = UIButton(type: .system)
        shuffle.setImage(UIImage(systemName: "shuffle"), for: .normal)
        shuffle.tintColor = .white
        shuffle.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        shuffle.layer.cornerRadius = 18
        shuffle.addTarget(self, action: #selector(shuffleNow), for: .touchUpInside)
        shuffle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shuffle)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            title.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            shuffle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            shuffle.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            shuffle.widthAnchor.constraint(equalToConstant: 36),
            shuffle.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collectionView.bounds.size

        if layout.itemSize != size {
            layout.itemSize = size
            layout.invalidateLayout()

            if let currentID,
               let index = items.firstIndex(where: { $0.id == currentID }) {
                collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playCenteredCell()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visibleCells().forEach { $0.pause() }
    }

    func reloadPreservingPosition() {
        currentID = centeredItem()?.id ?? currentID
        items = store.media
        collectionView.reloadData()
        collectionView.layoutIfNeeded()

        if let currentID,
           let index = items.firstIndex(where: { $0.id == currentID }) {
            collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)
        }
    }

    func open(mediaID: String) {
        items = store.media
        collectionView.reloadData()
        collectionView.layoutIfNeeded()

        guard let index = items.firstIndex(where: { $0.id == mediaID }) else { return }
        currentID = mediaID
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)

        DispatchQueue.main.async {
            self.playCenteredCell()
        }
    }

    @objc func shuffleNow() {
        items = store.media.shuffled()
        currentID = items.first?.id
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)

        DispatchQueue.main.async {
            self.playCenteredCell()
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FeedCell.reuseID, for: indexPath) as! FeedCell
        let item = items[indexPath.item]
        cell.configure(item: item, creator: store.creator(for: item), liked: store.isLiked(item.id))
        cell.onLike = { [weak self] in
            self?.store.toggleLike(item.id)
        }
        cell.onMore = { [weak self] source in
            self?.showActions(for: item, source: source)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let feedCell = cell as? FeedCell else { return }
        feedCell.preparePlayer(for: items[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? FeedCell)?.releasePlayer()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        visibleCells().forEach { $0.pause() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        playCenteredCell()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        playCenteredCell()
    }

    private func centeredItem() -> CBMedia? {
        let point = CGPoint(
            x: collectionView.bounds.midX + collectionView.contentOffset.x,
            y: collectionView.bounds.midY + collectionView.contentOffset.y
        )
        guard let indexPath = collectionView.indexPathForItem(at: point),
              indexPath.item < items.count else {
            return nil
        }
        return items[indexPath.item]
    }

    private func visibleCells() -> [FeedCell] {
        collectionView.visibleCells.compactMap { $0 as? FeedCell }
    }

    private func playCenteredCell() {
        guard view.window != nil else { return }

        let point = CGPoint(
            x: collectionView.bounds.midX + collectionView.contentOffset.x,
            y: collectionView.bounds.midY + collectionView.contentOffset.y
        )

        guard let indexPath = collectionView.indexPathForItem(at: point),
              indexPath.item < items.count else {
            return
        }

        currentID = items[indexPath.item].id

        for case let cell as FeedCell in collectionView.visibleCells {
            if collectionView.indexPath(for: cell) == indexPath {
                cell.play()
            } else {
                cell.pause()
            }
        }
    }

    private func showActions(for item: CBMedia, source: UIView) {
        let sheet = UIAlertController(title: item.name, message: nil, preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: store.isLiked(item.id) ? "Unlike" : "Like", style: .default) { _ in
            self.store.toggleLike(item.id)
        })

        sheet.addAction(UIAlertAction(title: "Change Creator", style: .default) { _ in
            self.showCreatorPicker(for: item)
        })

        sheet.addAction(UIAlertAction(title: "Delete Media", style: .destructive) { _ in
            let confirm = UIAlertController(title: "Delete media?", message: item.name, preferredStyle: .alert)
            confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            confirm.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
                self.store.deleteMedia(item.id)
            })
            self.present(confirm, animated: true)
        })

        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = sheet.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds
        }

        present(sheet, animated: true)
    }

    private func showCreatorPicker(for item: CBMedia) {
        let sheet = UIAlertController(title: "Assign Creator", message: nil, preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "Unassigned", style: .default) { _ in
            self.store.setCreator(nil, for: item.id)
        })

        for creator in store.creators {
            sheet.addAction(UIAlertAction(title: creator.name, style: .default) { _ in
                self.store.setCreator(creator.id, for: item.id)
            })
        }

        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }
}

final class FeedCell: UICollectionViewCell {
    static let reuseID = "FeedCell"

    var onLike: (() -> Void)?
    var onMore: ((UIView) -> Void)?

    private let playerView = PlayerSurfaceView()
    private let imageView = UIImageView()
    private let gradient = CAGradientLayer()
    private let avatar = UIImageView()
    private let creatorName = UILabel()
    private let creatorHandle = UILabel()
    private let fileName = UILabel()
    private let likeButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private var player: AVPlayer?
    private var representedID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.backgroundColor = .black
        addSubview(playerView)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        addSubview(imageView)

        gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.76).cgColor]
        gradient.locations = [0.48, 1]
        layer.addSublayer(gradient)

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.layer.cornerRadius = 21

        creatorName.textColor = .white
        creatorName.font = .systemFont(ofSize: 15, weight: .bold)

        creatorHandle.textColor = UIColor.white.withAlphaComponent(0.72)
        creatorHandle.font = .systemFont(ofSize: 12, weight: .medium)

        fileName.textColor = UIColor.white.withAlphaComponent(0.82)
        fileName.font = .systemFont(ofSize: 12)
        fileName.numberOfLines = 2

        let labels = UIStackView(arrangedSubviews: [creatorName, creatorHandle])
        labels.axis = .vertical
        labels.spacing = 1

        let creatorRow = UIStackView(arrangedSubviews: [avatar, labels])
        creatorRow.axis = .horizontal
        creatorRow.alignment = .center
        creatorRow.spacing = 9

        let info = UIStackView(arrangedSubviews: [creatorRow, fileName])
        info.axis = .vertical
        info.spacing = 7
        info.translatesAutoresizingMaskIntoConstraints = false
        addSubview(info)

        likeButton.tintColor = .white
        likeButton.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)

        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = .white
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)

        let actions = UIStackView(arrangedSubviews: [likeButton, moreButton])
        actions.axis = .vertical
        actions.spacing = 14
        actions.alignment = .center
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            avatar.widthAnchor.constraint(equalToConstant: 42),
            avatar.heightAnchor.constraint(equalToConstant: 42),

            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            info.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
            info.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -18),

            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            actions.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -18),
            likeButton.widthAnchor.constraint(equalToConstant: 44),
            likeButton.heightAnchor.constraint(equalToConstant: 44),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releasePlayer()
        representedID = nil
        imageView.image = nil
        avatar.image = nil
        onLike = nil
        onMore = nil
    }

    func configure(item: CBMedia, creator: CBCreator?, liked: Bool) {
        representedID = item.id
        creatorName.text = creator?.name ?? "Unassigned"
        creatorHandle.text = creator?.handle ?? ""
        creatorHandle.isHidden = creator?.handle.isEmpty ?? true
        fileName.text = item.name
        avatar.image = AvatarFactory.image(dataURL: creator?.photo, fallback: creator?.name ?? "?")

        likeButton.setImage(UIImage(systemName: liked ? "heart.fill" : "heart"), for: .normal)
        likeButton.tintColor = liked ? .systemOrange : .white

        if item.kind == .image {
            playerView.isHidden = true
            imageView.isHidden = false
            imageView.image = ImageLoader.downsample(item.url, maxDimension: 1800)
        } else {
            playerView.isHidden = false
            imageView.isHidden = true
        }
    }

    func preparePlayer(for item: CBMedia) {
        guard item.kind == .video,
              representedID == item.id,
              player == nil else {
            return
        }

        let asset = AVURLAsset(url: item.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 3
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        player = newPlayer
        playerView.player = newPlayer
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerView.player = nil
        player = nil
    }

    @objc private func likeTapped() {
        onLike?()
    }

    @objc private func moreTapped() {
        onMore?(moreButton)
    }
}

final class PlayerSurfaceView: UIView {
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError()
    }
}

enum LibraryFilter: Int, CaseIterable {
    case all
    case videos
    case photos
    case unassigned
    case liked

    var title: String {
        switch self {
        case .all: return "All"
        case .videos: return "Videos"
        case .photos: return "Photos"
        case .unassigned: return "Unassigned"
        case .liked: return "Liked"
        }
    }
}

final class LibraryViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UISearchResultsUpdating {
    private let store: CornBoxStore
    private var collectionView: UICollectionView!
    private var filter: LibraryFilter = .all
    private var query = ""
    private var items: [CBMedia] = []

    init(store: CornBoxStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = "Library"
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let layout = UICollectionViewCompositionalLayout { _, environment in
            let gap: CGFloat = 2
            let width = (environment.container.effectiveContentSize.width - gap * 2) / 3
            let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(width), heightDimension: .absolute(width * 1.45))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(width * 1.45))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item, item, item])
            group.interItemSpacing = .fixed(gap)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = gap
            return section
        }

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .black
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(LibraryCell.self, forCellWithReuseIdentifier: LibraryCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let segmented = UISegmentedControl(items: LibraryFilter.allCases.map { $0.title })
        segmented.selectedSegmentIndex = 0
        segmented.addTarget(self, action: #selector(filterChanged(_:)), for: .valueChanged)
        navigationItem.titleView = segmented

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search media or creator"
        navigationItem.searchController = search

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "shuffle"),
            style: .plain,
            target: self,
            action: #selector(shuffleTapped)
        )

        reloadData()
    }

    func reloadData() {
        var result = store.media

        switch filter {
        case .all:
            break
        case .videos:
            result = result.filter { $0.kind == .video }
        case .photos:
            result = result.filter { $0.kind == .image }
        case .unassigned:
            result = result.filter { $0.creatorID == nil }
        case .liked:
            result = result.filter { store.isLiked($0.id) }
        }

        if !query.isEmpty {
            result = result.filter { item in
                if item.name.localizedCaseInsensitiveContains(query) {
                    return true
                }

                guard let creator = store.creator(for: item) else {
                    return false
                }

                return creator.name.localizedCaseInsensitiveContains(query) || creator.handle.localizedCaseInsensitiveContains(query)
            }
        }

        items = result

        if isViewLoaded {
            collectionView.reloadData()
        }
    }

    @objc private func filterChanged(_ sender: UISegmentedControl) {
        filter = LibraryFilter(rawValue: sender.selectedSegmentIndex) ?? .all
        reloadData()
    }

    @objc private func shuffleTapped() {
        (tabBarController as? CornBoxTabController)?.shuffleFeed()
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        reloadData()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: LibraryCell.reuseID, for: indexPath) as! LibraryCell
        let item = items[indexPath.item]
        cell.configure(item: item, creator: store.creator(for: item))
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        (tabBarController as? CornBoxTabController)?.showFeedItem(items[indexPath.item].id)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let item = items[indexPath.item]

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let like = UIAction(
                title: self.store.isLiked(item.id) ? "Unlike" : "Like",
                image: UIImage(systemName: "heart")
            ) { _ in
                self.store.toggleLike(item.id)
            }

            let unassigned = UIAction(title: "Unassigned") { _ in
                self.store.setCreator(nil, for: item.id)
            }

            let creatorActions = self.store.creators.map { creator in
                UIAction(title: creator.name) { _ in
                    self.store.setCreator(creator.id, for: item.id)
                }
            }

            let creatorMenu = UIMenu(
                title: "Creator",
                image: UIImage(systemName: "person.crop.circle"),
                children: [unassigned] + creatorActions
            )

            let delete = UIAction(
                title: "Delete",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                self.store.deleteMedia(item.id)
            }

            return UIMenu(children: [like, creatorMenu, delete])
        }
    }
}

final class LibraryCell: UICollectionViewCell {
    static let reuseID = "LibraryCell"

    private let imageView = UIImageView()
    private let creatorLabel = UILabel()
    private let playIcon = UIImageView()
    private var token = UUID()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.08, alpha: 1)
        clipsToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)

        creatorLabel.translatesAutoresizingMaskIntoConstraints = false
        creatorLabel.textColor = .white
        creatorLabel.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        creatorLabel.font = .systemFont(ofSize: 10, weight: .bold)
        creatorLabel.layer.cornerRadius = 5
        creatorLabel.clipsToBounds = true
        creatorLabel.textAlignment = .center
        addSubview(creatorLabel)

        playIcon.image = UIImage(systemName: "play.fill")
        playIcon.tintColor = .white
        playIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playIcon)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            creatorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            creatorLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5),
            creatorLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            creatorLabel.heightAnchor.constraint(equalToConstant: 22),

            playIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            playIcon.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        token = UUID()
        imageView.image = nil
    }

    func configure(item: CBMedia, creator: CBCreator?) {
        creatorLabel.text = "  \(creator?.name ?? "Unassigned")  "
        playIcon.isHidden = item.kind != .video

        if item.kind == .image {
            imageView.image = ImageLoader.downsample(item.url, maxDimension: 500)
            return
        }

        let currentToken = UUID()
        token = currentToken
        ThumbnailCache.shared.image(for: item.url) { [weak self] image in
            guard let self, self.token == currentToken else { return }
            self.imageView.image = image
        }
    }
}

final class CreatorsViewController: UITableViewController {
    private let store: CornBoxStore

    init(store: CornBoxStore) {
        self.store = store
        super.init(style: .insetGrouped)
        title = "Creators"
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addCreator)
        )
    }

    func reloadData() {
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 3 : max(store.creators.count, 1)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Library" : "Creator Profiles"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)

            if indexPath.row == 0 {
                cell.textLabel?.text = "Media"
                cell.detailTextLabel?.text = "\(store.media.count)"
            } else if indexPath.row == 1 {
                cell.textLabel?.text = "Creators"
                cell.detailTextLabel?.text = "\(store.creators.count)"
            } else {
                cell.textLabel?.text = "Assigned"
                cell.detailTextLabel?.text = "\(store.media.filter { $0.creatorID != nil }.count)"
            }

            cell.selectionStyle = .none
            return cell
        }

        guard !store.creators.isEmpty else {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.textLabel?.text = "No creators"
            cell.detailTextLabel?.text = "Tap + to create one"
            cell.selectionStyle = .none
            return cell
        }

        let creator = store.creators[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = creator.name
        cell.detailTextLabel?.text = "\(creator.handle) • \(store.creatorCount(creator.id)) media"
        cell.imageView?.image = AvatarFactory.image(dataURL: creator.photo, fallback: creator.name)
        cell.imageView?.layer.cornerRadius = 20
        cell.imageView?.clipsToBounds = true
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1, !store.creators.isEmpty else { return }
        editCreator(store.creators[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1, !store.creators.isEmpty else { return nil }
        let creator = store.creators[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
            self.store.deleteCreator(creator.id)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    @objc private func addCreator() {
        editCreator(nil)
    }

    private func editCreator(_ creator: CBCreator?) {
        let alert = UIAlertController(title: creator == nil ? "New Creator" : "Edit Creator", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "Name"
            $0.text = creator?.name
        }
        alert.addTextField {
            $0.placeholder = "@handle"
            $0.text = creator?.handle
        }
        alert.addTextField {
            $0.placeholder = "Bio"
            $0.text = creator?.bio
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return }

            self.store.saveCreator(CBCreator(
                id: creator?.id ?? UUID().uuidString,
                name: name,
                handle: alert.textFields?[1].text ?? "",
                bio: alert.textFields?[2].text ?? "",
                photo: creator?.photo
            ))
        })
        present(alert, animated: true)
    }
}

final class ActivityViewController: UITableViewController {
    private let store: CornBoxStore
    private var items: [CBActivity] = []

    init(store: CornBoxStore) {
        self.store = store
        super.init(style: .insetGrouped)
        title = "Activity"
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadData()
    }

    func reloadData() {
        items = store.activities()
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(items.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)

        guard !items.isEmpty else {
            cell.textLabel?.text = "No activity yet"
            cell.detailTextLabel?.text = "Imports, likes and assignments will appear here."
            cell.selectionStyle = .none
            return cell
        }

        let item = items[indexPath.row]
        cell.textLabel?.text = item.title
        cell.detailTextLabel?.text = item.detail
        cell.imageView?.image = UIImage(systemName: item.type == "like" ? "heart" : "clock")
        cell.selectionStyle = .none
        return cell
    }
}

final class MigrationController: UIViewController, WKNavigationDelegate {
    private let store: CornBoxStore
    private let completion: (String) -> Void
    private var webView: WKWebView!
    private var attempted = false

    init(store: CornBoxStore, completion: @escaping (String) -> Void) {
        self.store = store
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        view.addSubview(webView)

        if store.fileExists(store.legacyHTMLURL) {
            webView.loadFileURL(store.legacyHTMLURL, allowingReadAccessTo: store.rootDirectory)
        } else if let bundled = Bundle.main.url(forResource: "app", withExtension: "html") {
            do {
                try store.copyLegacyHTMLIfNeeded(from: bundled)
                webView.loadFileURL(store.legacyHTMLURL, allowingReadAccessTo: store.rootDirectory)
            } catch {
                finish("Media preserved; migration source unavailable")
            }
        } else {
            finish("Media preserved; migration source unavailable")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !attempted else { return }
        attempted = true
        store.migrate(from: webView) { [weak self] message in
            self?.finish(message)
        }
    }

    private func finish(_ message: String) {
        completion(message)
        willMove(toParent: nil)
        view.removeFromSuperview()
        removeFromParent()
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "cornbox.thumbnail.queue", qos: .utility)

    func image(for url: URL, completion: @escaping (UIImage?) -> Void) {
        let key = url.path as NSString

        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        queue.async {
            autoreleasepool {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 420, height: 720)

                let image: UIImage?

                if let cgImage = try? generator.copyCGImage(
                    at: CMTime(seconds: 0.15, preferredTimescale: 600),
                    actualTime: nil
                ) {
                    let uiImage = UIImage(cgImage: cgImage)
                    self.cache.setObject(uiImage, forKey: key)
                    image = uiImage
                } else {
                    image = nil
                }

                DispatchQueue.main.async {
                    completion(image)
                }
            }
        }
    }
}

enum ImageLoader {
    static func downsample(_ url: URL, maxDimension: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return UIImage(contentsOfFile: url.path)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(contentsOfFile: url.path)
        }

        return UIImage(cgImage: cgImage)
    }
}

enum AvatarFactory {
    static func image(dataURL: String?, fallback: String) -> UIImage {
        if let dataURL,
           let comma = dataURL.firstIndex(of: ","),
           let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
           let image = UIImage(data: data) {
            return image
        }

        let size = CGSize(width: 80, height: 80)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.18, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let text = String(fallback.prefix(1)).uppercased()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }
}
