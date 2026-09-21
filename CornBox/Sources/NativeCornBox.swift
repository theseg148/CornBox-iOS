import SwiftUI
import UIKit
import AVFoundation
import WebKit
import UniformTypeIdentifiers
import ImageIO

struct RootView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { CornBoxTabs(store: .shared) }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct Creator: Codable, Hashable {
    var id: String
    var name: String
    var handle: String
    var bio: String
    var photo: String?
}

struct MediaItem: Hashable {
    enum Kind: String { case video, image }
    let id: String
    let name: String
    let url: URL
    let kind: Kind
    var creatorID: String?
}

struct NativeState: Codable {
    var creators: [Creator] = []
    var assignments: [String:String] = [:]
    var liked: [String:Bool] = [:]
    var commentsRaw: String?
    var albumsRaw: String?
    var historyRaw: String?
    var activityRaw: String?
    var migrated = false
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

struct ActivityEntry {
    let title: String
    let detail: String
    let type: String
    let timestamp: Double
}

final class CornBoxStore {
    static let shared = CornBoxStore()
    let fm = FileManager.default
    let root: URL
    let mediaDir: URL
    let stateURL: URL
    let backupURL: URL
    let legacyHTML: URL
    private(set) var state = NativeState()
    private(set) var media: [MediaItem] = []
    var onChange: (() -> Void)?

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = base.appendingPathComponent("CornBox", isDirectory: true)
        mediaDir = root.appendingPathComponent("media", isDirectory: true)
        stateURL = root.appendingPathComponent("native-state-v2.json")
        backupURL = root.appendingPathComponent("migration-backup-v2.json")
        legacyHTML = root.appendingPathComponent("app.html")
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        load()
        scan(notify: false)
    }

    var creators: [Creator] { state.creators }
    func creator(for item: MediaItem) -> Creator? {
        guard let id = item.creatorID else { return nil }
        return state.creators.first { $0.id == id }
    }
    func creatorCount(_ id: String) -> Int { media.filter { $0.creatorID == id }.count }
    func isLiked(_ id: String) -> Bool { state.liked[id] == true }

    func toggleLike(_ id: String) {
        state.liked[id] = !(state.liked[id] ?? false)
        persist()
    }

    func setCreator(_ creatorID: String?, mediaID: String) {
        if let creatorID { state.assignments[mediaID] = creatorID }
        else { state.assignments.removeValue(forKey: mediaID) }
        scan(notify: false)
        persist()
    }

    func saveCreator(_ creator: Creator) {
        if let i = state.creators.firstIndex(where: { $0.id == creator.id }) { state.creators[i] = creator }
        else { state.creators.append(creator) }
        persist()
    }

    func deleteCreator(_ id: String) {
        state.creators.removeAll { $0.id == id }
        state.assignments = state.assignments.filter { $0.value != id }
        scan(notify: false)
        persist()
    }

    func deleteMedia(_ id: String) {
        guard let item = media.first(where: { $0.id == id }) else { return }
        try? fm.removeItem(at: item.url)
        state.assignments.removeValue(forKey: id)
        state.liked.removeValue(forKey: id)
        scan(notify: false)
        persist()
    }

    func scan(notify: Bool = true) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        let videos: Set<String> = ["mp4","mov","m4v","webm"]
        let images: Set<String> = ["jpg","jpeg","png","gif","webp","heic","heif"]
        let sorted = urls.sorted {
            let a = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return a > b
        }
        media = sorted.compactMap { url in
            let ext = url.pathExtension.lowercased()
            let kind: MediaItem.Kind
            if videos.contains(ext) { kind = .video }
            else if images.contains(ext) { kind = .image }
            else { return nil }
            let id = url.lastPathComponent
            return MediaItem(id: id, name: id, url: url, kind: kind, creatorID: state.assignments[id])
        }
        if notify { onChange?() }
    }

    func importFiles(_ urls: [URL], completion: @escaping () -> Void) {
        guard !urls.isEmpty else { completion(); return }
        let destDir = mediaDir
        DispatchQueue.global(qos: .userInitiated).async {
            for source in urls {
                autoreleasepool {
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    let original = source.lastPathComponent
                    let stem = (original as NSString).deletingPathExtension
                    let ext = (original as NSString).pathExtension
                    var dest = destDir.appendingPathComponent(original)
                    var n = 2
                    while FileManager.default.fileExists(atPath: dest.path) {
                        let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                        dest = destDir.appendingPathComponent(name)
                        n += 1
                    }
                    try? FileManager.default.copyItem(at: source, to: dest)
                }
            }
            DispatchQueue.main.async {
                self.scan()
                completion()
            }
        }
    }

    func activities() -> [ActivityEntry] {
        guard let raw = state.activityRaw,
              let data = raw.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String:Any]] else { return [] }
        return rows.map { row in
            ActivityEntry(title: row["title"] as? String ?? row["type"] as? String ?? "Activity",
                          detail: row["detail"] as? String ?? "",
                          type: row["type"] as? String ?? "activity",
                          timestamp: (row["ts"] as? NSNumber)?.doubleValue ?? 0)
        }.sorted { $0.timestamp > $1.timestamp }
    }

    func migrate(from webView: WKWebView, completion: @escaping (String) -> Void) {
        guard !state.migrated else { completion("Migration already complete"); return }
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
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(MigrationSnapshot.self, from: data) else {
                self.state.migrated = true
                self.save()
                completion("Existing media kept; legacy metadata was unavailable")
                return
            }
            try? data.write(to: self.backupURL, options: .atomic)
            if let raw = snapshot.creators,
               let d = raw.data(using: .utf8),
               let rows = try? JSONSerialization.jsonObject(with: d) as? [[String:Any]] {
                self.state.creators = rows.compactMap { row in
                    guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                    return Creator(id: id, name: name, handle: row["handle"] as? String ?? "", bio: row["bio"] as? String ?? "", photo: row["photo"] as? String)
                }
            }
            if let raw = snapshot.assignments,
               let d = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String:String].self, from: d) { self.state.assignments = decoded }
            if let raw = snapshot.liked,
               let d = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String:Bool].self, from: d) { self.state.liked = decoded }
            self.state.commentsRaw = snapshot.comments
            self.state.albumsRaw = snapshot.albums
            self.state.historyRaw = snapshot.history
            self.state.activityRaw = snapshot.activity
            self.state.migrated = true
            self.save()
            self.scan(notify: false)
            self.onChange?()
            completion("Migrated \(self.state.creators.count) creators")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL), let decoded = try? JSONDecoder().decode(NativeState.self, from: data) else { return }
        state = decoded
    }
    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
    private func persist() { save(); onChange?() }
}

final class CornBoxTabs: UITabBarController, UITabBarControllerDelegate, UIDocumentPickerDelegate {
    let store: CornBoxStore
    let feed: FeedViewController
    let library: LibraryViewController
    let activity: ActivityViewController
    let creators: CreatorsViewController
    let addVC = UIViewController()
    var migration: MigrationController?

    init(store: CornBoxStore) {
        self.store = store
        feed = FeedViewController(store: store)
        library = LibraryViewController(store: store)
        activity = ActivityViewController(store: store)
        creators = CreatorsViewController(store: store)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        view.backgroundColor = .black
        let homeNav = UINavigationController(rootViewController: feed)
        homeNav.setNavigationBarHidden(true, animated: false)
        let libNav = UINavigationController(rootViewController: library)
        let actNav = UINavigationController(rootViewController: activity)
        let crNav = UINavigationController(rootViewController: creators)
        homeNav.tabBarItem = UITabBarItem(title: "Home", image: UIImage(systemName: "house.fill"), tag: 0)
        libNav.tabBarItem = UITabBarItem(title: "Library", image: UIImage(systemName: "square.grid.2x2.fill"), tag: 1)
        addVC.tabBarItem = UITabBarItem(title: "Add", image: UIImage(systemName: "plus.square.fill"), tag: 2)
        actNav.tabBarItem = UITabBarItem(title: "Activity", image: UIImage(systemName: "clock.arrow.circlepath"), tag: 3)
        crNav.tabBarItem = UITabBarItem(title: "Creators", image: UIImage(systemName: "person.2.fill"), tag: 4)
        viewControllers = [homeNav, libNav, addVC, actNav, crNav]
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
        if !store.state.migrated { beginMigration() }
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if viewController === addVC { presentImporter(); return false }
        return true
    }

    func presentImporter() {
        let sheet = UIAlertController(title: "Add media", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Files", style: .default) { _ in self.presentFilePicker() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController { pop.sourceView = tabBar; pop.sourceRect = tabBar.bounds }
        present(sheet, animated: true)
    }

    func presentFilePicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image,.movie], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let alert = UIAlertController(title: "Importing", message: "Adding \(urls.count) item\(urls.count == 1 ? "" : "s")…", preferredStyle: .alert)
        present(alert, animated: true)
        store.importFiles(urls) { alert.dismiss(animated: true) }
    }

    func beginMigration() {
        let vc = MigrationController(store: store) { [weak self] _ in self?.migration = nil }
        migration = vc
        addChild(vc)
        vc.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        vc.view.alpha = 0.001
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
    }
}

final class FeedViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    let store: CornBoxStore
    let layout = UICollectionViewFlowLayout()
    lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    var items: [MediaItem]
    var currentID: String?
    let titleLabel = UILabel()
    let shuffleButton = UIButton(type: .system)

    init(store: CornBoxStore) { self.store = store; items = store.media; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        collection.backgroundColor = .black
        collection.isPagingEnabled = true
        collection.alwaysBounceVertical = false
        collection.showsVerticalScrollIndicator = false
        collection.contentInsetAdjustmentBehavior = .never
        collection.dataSource = self
        collection.delegate = self
        collection.register(FeedCell.self, forCellWithReuseIdentifier: FeedCell.id)
        collection.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collection)
        titleLabel.text = "For You"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        shuffleButton.setImage(UIImage(systemName: "shuffle"), for: .normal)
        shuffleButton.tintColor = .white
        shuffleButton.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        shuffleButton.layer.cornerRadius = 18
        shuffleButton.addTarget(self, action: #selector(shuffleNow), for: .touchUpInside)
        shuffleButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)
        view.addSubview(shuffleButton)
        NSLayoutConstraint.activate([
            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor), collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collection.topAnchor.constraint(equalTo: view.topAnchor), collection.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8), titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shuffleButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), shuffleButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            shuffleButton.widthAnchor.constraint(equalToConstant: 36), shuffleButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collection.bounds.size
        if layout.itemSize != size {
            layout.itemSize = size
            layout.invalidateLayout()
            if let currentID, let idx = items.firstIndex(where: { $0.id == currentID }) {
                collection.scrollToItem(at: IndexPath(item: idx, section: 0), at: .top, animated: false)
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); playCentered() }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); cells().forEach { $0.pause() } }

    func reloadPreservingPosition() {
        currentID = centered()?.id ?? currentID
        items = store.media
        collection.reloadData()
        collection.layoutIfNeeded()
        if let currentID, let idx = items.firstIndex(where: { $0.id == currentID }) {
            collection.scrollToItem(at: IndexPath(item: idx, section: 0), at: .top, animated: false)
        }
    }

    func open(_ mediaID: String) {
        items = store.media
        collection.reloadData()
        collection.layoutIfNeeded()
        guard let idx = items.firstIndex(where: { $0.id == mediaID }) else { return }
        currentID = mediaID
        collection.scrollToItem(at: IndexPath(item: idx, section: 0), at: .top, animated: false)
        DispatchQueue.main.async { self.playCentered() }
    }

    @objc func shuffleNow() {
        items = store.media.shuffled()
        currentID = items.first?.id
        collection.reloadData()
        collection.setContentOffset(.zero, animated: false)
        DispatchQueue.main.async { self.playCentered() }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FeedCell.id, for: indexPath) as! FeedCell
        let item = items[indexPath.item]
        cell.configure(item: item, creator: store.creator(for: item), liked: store.isLiked(item.id))
        cell.onLike = { [weak self] in self?.store.toggleLike(item.id) }
        cell.onMore = { [weak self] source in self?.showActions(item, source: source) }
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? FeedCell)?.preparePlayer(for: items[indexPath.item])
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) { (cell as? FeedCell)?.releasePlayer() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { cells().forEach { $0.pause() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { playCentered() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { playCentered() }

    func centered() -> MediaItem? {
        let p = CGPoint(x: collection.bounds.midX + collection.contentOffset.x, y: collection.bounds.midY + collection.contentOffset.y)
        guard let ip = collection.indexPathForItem(at: p), ip.item < items.count else { return nil }
        return items[ip.item]
    }
    func cells() -> [FeedCell] { collection.visibleCells.compactMap { $0 as? FeedCell } }
    func playCentered() {
        guard view.window != nil else { return }
        let p = CGPoint(x: collection.bounds.midX + collection.contentOffset.x, y: collection.bounds.midY + collection.contentOffset.y)
        guard let ip = collection.indexPathForItem(at: p), ip.item < items.count else { return }
        currentID = items[ip.item].id
        for case let c as FeedCell in collection.visibleCells { collection.indexPath(for: c) == ip ? c.play() : c.pause() }
    }

    func showActions(_ item: MediaItem, source: UIView) {
        let sheet = UIAlertController(title: item.name, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: store.isLiked(item.id) ? "Unlike" : "Like", style: .default) { _ in self.store.toggleLike(item.id) })
        sheet.addAction(UIAlertAction(title: "Change Creator", style: .default) { _ in self.showCreatorPicker(item) })
        sheet.addAction(UIAlertAction(title: "Delete Media", style: .destructive) { _ in
            let confirm = UIAlertController(title: "Delete media?", message: item.name, preferredStyle: .alert)
            confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            confirm.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in self.store.deleteMedia(item.id) })
            self.present(confirm, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController { pop.sourceView = source; pop.sourceRect = source.bounds }
        present(sheet, animated: true)
    }
    func showCreatorPicker(_ item: MediaItem) {
        let sheet = UIAlertController(title: "Assign Creator", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Unassigned", style: .default) { _ in self.store.setCreator(nil, mediaID: item.id) })
        for c in store.creators { sheet.addAction(UIAlertAction(title: c.name, style: .default) { _ in self.store.setCreator(c.id, mediaID: item.id) }) }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }
}

final class FeedCell: UICollectionViewCell {
    static let id = "FeedCell"
    var onLike: (() -> Void)?
    var onMore: ((UIView) -> Void)?
    let playerView = PlayerView()
    let imageView = UIImageView()
    let gradient = CAGradientLayer()
    let avatar = UIImageView()
    let creatorName = UILabel()
    let handle = UILabel()
    let fileName = UILabel()
    let likeButton = UIButton(type: .system)
    let moreButton = UIButton(type: .system)
    var player: AVPlayer?
    var representedID: String?

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
        handle.textColor = UIColor.white.withAlphaComponent(0.72)
        handle.font = .systemFont(ofSize: 12, weight: .medium)
        fileName.textColor = UIColor.white.withAlphaComponent(0.82)
        fileName.font = .systemFont(ofSize: 12)
        fileName.numberOfLines = 2
        let labels = UIStackView(arrangedSubviews: [creatorName, handle]); labels.axis = .vertical; labels.spacing = 1
        let creatorRow = UIStackView(arrangedSubviews: [avatar, labels]); creatorRow.axis = .horizontal; creatorRow.alignment = .center; creatorRow.spacing = 9
        let info = UIStackView(arrangedSubviews: [creatorRow, fileName]); info.axis = .vertical; info.spacing = 7; info.translatesAutoresizingMaskIntoConstraints = false
        addSubview(info)
        likeButton.tintColor = .white
        likeButton.addTarget(self, action: #selector(likeTap), for: .touchUpInside)
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = .white
        moreButton.addTarget(self, action: #selector(moreTap), for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [likeButton, moreButton]); actions.axis = .vertical; actions.spacing = 14; actions.alignment = .center; actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor), playerView.trailingAnchor.constraint(equalTo: trailingAnchor), playerView.topAnchor.constraint(equalTo: topAnchor), playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor), imageView.trailingAnchor.constraint(equalTo: trailingAnchor), imageView.topAnchor.constraint(equalTo: topAnchor), imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 42), avatar.heightAnchor.constraint(equalToConstant: 42),
            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), info.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12), info.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -18),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), actions.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -18),
            likeButton.widthAnchor.constraint(equalToConstant: 44), likeButton.heightAnchor.constraint(equalToConstant: 44), moreButton.widthAnchor.constraint(equalToConstant: 44), moreButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); gradient.frame = bounds }
    override func prepareForReuse() { super.prepareForReuse(); releasePlayer(); representedID = nil; imageView.image = nil; avatar.image = nil; onLike = nil; onMore = nil }

    func configure(item: MediaItem, creator: Creator?, liked: Bool) {
        representedID = item.id
        creatorName.text = creator?.name ?? "Unassigned"
        handle.text = creator?.handle ?? ""
        handle.isHidden = creator?.handle.isEmpty ?? true
        fileName.text = item.name
        avatar.image = Avatar.image(dataURL: creator?.photo, fallback: creator?.name ?? "?")
        likeButton.setImage(UIImage(systemName: liked ? "heart.fill" : "heart"), for: .normal)
        likeButton.tintColor = liked ? .systemOrange : .white
        if item.kind == .image {
            playerView.isHidden = true; imageView.isHidden = false
            imageView.image = ImageLoader.downsample(item.url, max: 1800)
        } else { playerView.isHidden = false; imageView.isHidden = true }
    }
    func preparePlayer(for item: MediaItem) {
        guard item.kind == .video, representedID == item.id, player == nil else { return }
        let asset = AVURLAsset(url: item.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey:false])
        let pItem = AVPlayerItem(asset: asset); pItem.preferredForwardBufferDuration = 3
        let p = AVPlayer(playerItem: pItem); p.automaticallyWaitsToMinimizeStalling = true
        player = p; playerView.player = p
    }
    func play() { player?.play() }
    func pause() { player?.pause() }
    func releasePlayer() { player?.pause(); player?.replaceCurrentItem(with: nil); playerView.player = nil; player = nil }
    @objc func likeTap() { onLike?() }
    @objc func moreTap() { onMore?(moreButton) }
}

final class PlayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? { get { playerLayer.player } set { playerLayer.player = newValue } }
    override init(frame: CGRect) { super.init(frame: frame); playerLayer.videoGravity = .resizeAspect; backgroundColor = .black }
    required init?(coder: NSCoder) { fatalError() }
}

enum LibraryFilter: Int, CaseIterable {
    case all, videos, photos, unassigned, liked
    var title: String { ["All","Videos","Photos","Unassigned","Liked"][rawValue] }
}

final class LibraryViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UISearchResultsUpdating {
    let store: CornBoxStore
    var collection: UICollectionView!
    var filter: LibraryFilter = .all
    var query = ""
    var items: [MediaItem] = []
    init(store: CornBoxStore) { self.store = store; super.init(nibName: nil, bundle: nil); title = "Library" }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let layout = UICollectionViewCompositionalLayout { _, env in
            let gap: CGFloat = 2
            let w = (env.container.effectiveContentSize.width - gap*2)/3
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(w), heightDimension: .absolute(w*1.45)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(w*1.45)), subitems: [item,item,item])
            group.interItemSpacing = .fixed(gap)
            let section = NSCollectionLayoutSection(group: group); section.interGroupSpacing = gap; return section
        }
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .black; collection.dataSource = self; collection.delegate = self
        collection.register(LibraryCell.self, forCellWithReuseIdentifier: LibraryCell.id)
        collection.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(collection)
        NSLayoutConstraint.activate([collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),collection.topAnchor.constraint(equalTo: view.topAnchor),collection.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        let seg = UISegmentedControl(items: LibraryFilter.allCases.map(\.title)); seg.selectedSegmentIndex = 0; seg.addTarget(self, action: #selector(filterChanged(_:)), for: .valueChanged); navigationItem.titleView = seg
        let search = UISearchController(searchResultsController: nil); search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false; search.searchBar.placeholder = "Search media or creator"; navigationItem.searchController = search
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "shuffle"), style: .plain, target: self, action: #selector(shuffle))
        reloadData()
    }
    func reloadData() {
        var result = store.media
        switch filter { case .all: break; case .videos: result = result.filter{$0.kind == .video}; case .photos: result = result.filter{$0.kind == .image}; case .unassigned: result = result.filter{$0.creatorID == nil}; case .liked: result = result.filter{store.isLiked($0.id)} }
        if !query.isEmpty { result = result.filter { item in item.name.localizedCaseInsensitiveContains(query) || (store.creator(for:item)?.name.localizedCaseInsensitiveContains(query) ?? false) || (store.creator(for:item)?.handle.localizedCaseInsensitiveContains(query) ?? false) } }
        items = result; if isViewLoaded { collection.reloadData() }
    }
    @objc func filterChanged(_ sender: UISegmentedControl) { filter = LibraryFilter(rawValue: sender.selectedSegmentIndex) ?? .all; reloadData() }
    @objc func shuffle() { guard let tab = tabBarController as? CornBoxTabs else { return }; tab.selectedIndex = 0; tab.feed.shuffleNow() }
    func updateSearchResults(for searchController: UISearchController) { query = searchController.searchBar.text ?? ""; reloadData() }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: LibraryCell.id, for: indexPath) as! LibraryCell
        let item = items[indexPath.item]; cell.configure(item: item, creator: store.creator(for: item)); return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { guard let tab = tabBarController as? CornBoxTabs else { return }; tab.feed.open(items[indexPath.item].id); tab.selectedIndex = 0 }
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let item = items[indexPath.item]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let like = UIAction(title: self.store.isLiked(item.id) ? "Unlike" : "Like", image: UIImage(systemName:"heart")) { _ in self.store.toggleLike(item.id) }
            let unassigned = UIAction(title:"Unassigned") { _ in self.store.setCreator(nil, mediaID:item.id) }
            let creatorActions = self.store.creators.map { c in UIAction(title:c.name) { _ in self.store.setCreator(c.id, mediaID:item.id) } }
            let creatorMenu = UIMenu(title:"Creator", image:UIImage(systemName:"person.crop.circle"), children:[unassigned] + creatorActions)
            let delete = UIAction(title:"Delete", image:UIImage(systemName:"trash"), attributes:.destructive) { _ in self.store.deleteMedia(item.id) }
            return UIMenu(children:[like,creatorMenu,delete])
        }
    }
}

final class LibraryCell: UICollectionViewCell {
    static let id = "LibraryCell"
    let imageView = UIImageView(); let label = UILabel(); let play = UIImageView(); var token = UUID()
    override init(frame:CGRect) {
        super.init(frame:frame); backgroundColor = UIColor(white:0.08,alpha:1); clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false; imageView.contentMode = .scaleAspectFill; imageView.clipsToBounds = true; addSubview(imageView)
        label.translatesAutoresizingMaskIntoConstraints = false; label.textColor = .white; label.backgroundColor = UIColor.black.withAlphaComponent(0.62); label.font = .systemFont(ofSize:10,weight:.bold); label.layer.cornerRadius = 5; label.clipsToBounds = true; label.textAlignment = .center; addSubview(label)
        play.image = UIImage(systemName:"play.fill"); play.tintColor = .white; play.translatesAutoresizingMaskIntoConstraints = false; addSubview(play)
        NSLayoutConstraint.activate([imageView.leadingAnchor.constraint(equalTo:leadingAnchor),imageView.trailingAnchor.constraint(equalTo:trailingAnchor),imageView.topAnchor.constraint(equalTo:topAnchor),imageView.bottomAnchor.constraint(equalTo:bottomAnchor),label.leadingAnchor.constraint(equalTo:leadingAnchor,constant:5),label.trailingAnchor.constraint(lessThanOrEqualTo:trailingAnchor,constant:-5),label.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-5),label.heightAnchor.constraint(equalToConstant:22),play.centerXAnchor.constraint(equalTo:centerXAnchor),play.centerYAnchor.constraint(equalTo:centerYAnchor)])
    }
    required init?(coder:NSCoder){fatalError()}
    override func prepareForReuse(){super.prepareForReuse(); token = UUID(); imageView.image = nil}
    func configure(item:MediaItem, creator:Creator?){label.text = "  \(creator?.name ?? "Unassigned")  "; play.isHidden = item.kind != .video; if item.kind == .image { imageView.image = ImageLoader.downsample(item.url,max:500) } else { let t = UUID(); token = t; ThumbnailCache.shared.image(item.url){[weak self] img in guard let self, self.token == t else{return}; self.imageView.image = img } } }
}

final class CreatorsViewController: UITableViewController {
    let store:CornBoxStore
    init(store:CornBoxStore){self.store=store;super.init(style:.insetGrouped);title="Creators"}
    required init?(coder:NSCoder){fatalError()}
    override func viewDidLoad(){super.viewDidLoad();navigationItem.rightBarButtonItem=UIBarButtonItem(barButtonSystemItem:.add,target:self,action:#selector(addCreator))}
    func reloadData(){if isViewLoaded{tableView.reloadData()}}
    override func numberOfSections(in tableView:UITableView)->Int{2}
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int)->Int{section==0 ? 3 : max(store.creators.count,1)}
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int)->String?{section==0 ? "Library" : "Creator Profiles"}
    override func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath)->UITableViewCell{
        if indexPath.section==0 { let c=UITableViewCell(style:.value1,reuseIdentifier:nil); if indexPath.row==0{c.textLabel?.text="Media";c.detailTextLabel?.text="\(store.media.count)"}else if indexPath.row==1{c.textLabel?.text="Creators";c.detailTextLabel?.text="\(store.creators.count)"}else{c.textLabel?.text="Assigned";c.detailTextLabel?.text="\(store.media.filter{$0.creatorID != nil}.count)"};c.selectionStyle=.none;return c }
        guard !store.creators.isEmpty else { let c=UITableViewCell(style:.subtitle,reuseIdentifier:nil);c.textLabel?.text="No creators";c.detailTextLabel?.text="Tap + to create one";c.selectionStyle=.none;return c }
        let cr=store.creators[indexPath.row];let c=UITableViewCell(style:.subtitle,reuseIdentifier:nil);c.textLabel?.text=cr.name;c.detailTextLabel?.text="\(cr.handle) • \(store.creatorCount(cr.id)) media";c.imageView?.image=Avatar.image(dataURL:cr.photo,fallback:cr.name);c.imageView?.layer.cornerRadius=20;c.imageView?.clipsToBounds=true;c.accessoryType=.disclosureIndicator;return c
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath){tableView.deselectRow(at:indexPath,animated:true);guard indexPath.section==1,!store.creators.isEmpty else{return};edit(store.creators[indexPath.row])}
    override func tableView(_ tableView:UITableView,trailingSwipeActionsConfigurationForRowAt indexPath:IndexPath)->UISwipeActionsConfiguration?{guard indexPath.section==1,!store.creators.isEmpty else{return nil};let cr=store.creators[indexPath.row];let d=UIContextualAction(style:.destructive,title:"Delete"){_,_,done in self.store.deleteCreator(cr.id);done(true)};return UISwipeActionsConfiguration(actions:[d])}
    @objc func addCreator(){edit(nil)}
    func edit(_ creator:Creator?){let a=UIAlertController(title:creator==nil ? "New Creator":"Edit Creator",message:nil,preferredStyle:.alert);a.addTextField{$0.placeholder="Name";$0.text=creator?.name};a.addTextField{$0.placeholder="@handle";$0.text=creator?.handle};a.addTextField{$0.placeholder="Bio";$0.text=creator?.bio};a.addAction(UIAlertAction(title:"Cancel",style:.cancel));a.addAction(UIAlertAction(title:"Save",style:.default){_ in let name=a.textFields?[0].text?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "";guard !name.isEmpty else{return};self.store.saveCreator(Creator(id:creator?.id ?? UUID().uuidString,name:name,handle:a.textFields?[1].text ?? "",bio:a.textFields?[2].text ?? "",photo:creator?.photo))});present(a,animated:true)}
}

final class ActivityViewController:UITableViewController{
    let store:CornBoxStore;var items:[ActivityEntry]=[]
    init(store:CornBoxStore){self.store=store;super.init(style:.insetGrouped);title="Activity"}
    required init?(coder:NSCoder){fatalError()}
    override func viewDidLoad(){super.viewDidLoad();reloadData()}
    func reloadData(){items=store.activities();if isViewLoaded{tableView.reloadData()}}
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int)->Int{max(items.count,1)}
    override func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath)->UITableViewCell{let c=UITableViewCell(style:.subtitle,reuseIdentifier:nil);guard !items.isEmpty else{c.textLabel?.text="No activity yet";c.detailTextLabel?.text="Imports, likes and assignments will appear here.";c.selectionStyle=.none;return c};let x=items[indexPath.row];c.textLabel?.text=x.title;c.detailTextLabel?.text=x.detail;c.imageView?.image=UIImage(systemName:x.type=="like" ? "heart":"clock");c.selectionStyle=.none;return c}
}

final class MigrationController:UIViewController,WKNavigationDelegate{
    let store:CornBoxStore;let done:(String)->Void;var web:WKWebView!;var attempted=false
    init(store:CornBoxStore,done:@escaping(String)->Void){self.store=store;self.done=done;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){fatalError()}
    override func viewDidLoad(){super.viewDidLoad();let cfg=WKWebViewConfiguration();cfg.websiteDataStore=.default();web=WKWebView(frame:.zero,configuration:cfg);web.navigationDelegate=self;view.addSubview(web);if store.fm.fileExists(atPath:store.legacyHTML.path){web.loadFileURL(store.legacyHTML,allowingReadAccessTo:store.root)}else if let bundled=Bundle.main.url(forResource:"app",withExtension:"html"){try? store.fm.copyItem(at:bundled,to:store.legacyHTML);web.loadFileURL(store.legacyHTML,allowingReadAccessTo:store.root)}else{finish("Existing media preserved")}}
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){guard !attempted else{return};attempted=true;store.migrate(from:webView){[weak self] msg in self?.finish(msg)}}
    func finish(_ msg:String){done(msg);willMove(toParent:nil);view.removeFromSuperview();removeFromParent()}
}

final class ThumbnailCache{
    static let shared=ThumbnailCache();let cache=NSCache<NSString,UIImage>();let queue=DispatchQueue(label:"cornbox.thumbs",qos:.utility)
    func image(_ url:URL,completion:@escaping(UIImage?)->Void){let key=url.path as NSString;if let x=cache.object(forKey:key){completion(x);return};queue.async{autoreleasepool{let asset=AVURLAsset(url:url);let gen=AVAssetImageGenerator(asset:asset);gen.appliesPreferredTrackTransform=true;gen.maximumSize=CGSize(width:420,height:720);let img:UIImage?;if let cg=try? gen.copyCGImage(at:CMTime(seconds:0.15,preferredTimescale:600),actualTime:nil){let ui=UIImage(cgImage:cg);self.cache.setObject(ui,forKey:key);img=ui}else{img=nil};DispatchQueue.main.async{completion(img)}}}}
}

enum ImageLoader{
    static func downsample(_ url:URL,max:CGFloat)->UIImage?{guard let src=CGImageSourceCreateWithURL(url as CFURL,nil) else{return UIImage(contentsOfFile:url.path)};let opts:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max,kCGImageSourceShouldCacheImmediately:true];guard let cg=CGImageSourceCreateThumbnailAtIndex(src,0,opts as CFDictionary) else{return UIImage(contentsOfFile:url.path)};return UIImage(cgImage:cg)}
}

enum Avatar{
    static func image(dataURL:String?,fallback:String)->UIImage{if let dataURL,let comma=dataURL.firstIndex(of:","),let data=Data(base64Encoded:String(dataURL[dataURL.index(after:comma)...])),let image=UIImage(data:data){return image};let size=CGSize(width:80,height:80);return UIGraphicsImageRenderer(size:size).image{ctx in UIColor(white:0.18,alpha:1).setFill();ctx.fill(CGRect(origin:.zero,size:size));let text=String(fallback.prefix(1)).uppercased();let attrs:[NSAttributedString.Key:Any]=[.font:UIFont.systemFont(ofSize:34,weight:.bold),.foregroundColor:UIColor.white];let s=text.size(withAttributes:attrs);text.draw(at:CGPoint(x:(size.width-s.width)/2,y:(size.height-s.height)/2),withAttributes:attrs)}}
}
