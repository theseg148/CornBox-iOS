import SwiftUI
import UIKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct RootViewV6: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { V6Tabs(store: .shared) }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct V6Creator: Codable, Hashable { let id: String; var name: String; var handle: String; var bio: String; var photo: String? }
struct V6Media: Hashable { enum Kind { case video, image }; let id: String; let url: URL; let kind: Kind; var creatorID: String? }

enum V6Theme {
    static let bg = UIColor(red: 0.055, green: 0.045, blue: 0.09, alpha: 1)
    static let card = UIColor(red: 0.12, green: 0.09, blue: 0.18, alpha: 1)
    static let purple = UIColor(red: 0.58, green: 0.35, blue: 1, alpha: 1)
    static let peach = UIColor(red: 1, green: 0.48, blue: 0.35, alpha: 1)
    static let cream = UIColor(red: 1, green: 0.94, blue: 0.82, alpha: 1)
    static let mint = UIColor(red: 0.4, green: 0.92, blue: 0.72, alpha: 1)
}

final class V6Store {
    static let shared = V6Store()
    let directory: URL
    var media: [V6Media] = []
    var creators: [V6Creator] = []
    private var assignments: [String: String] = [:]
    var changed: (() -> Void)?
    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CornBox")
        directory = root.appendingPathComponent("media")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ["native-state-v3.json", "native-state-v2.json", "native-state.json"] {
            let url = root.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            assignments = obj["assignments"] as? [String: String] ?? assignments
            if let rows = obj["creators"] as? [[String: Any]] {
                creators = rows.compactMap { row in
                    guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                    return V6Creator(id: id, name: name, handle: row["handle"] as? String ?? "", bio: row["bio"] as? String ?? "", photo: row["photo"] as? String)
                }
            }
            if !creators.isEmpty || !assignments.isEmpty { break }
        }
        scan()
    }
    func scan() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let video: Set<String> = ["mp4", "mov", "m4v"]
        let image: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
        media = urls.compactMap { url in
            let ext = url.pathExtension.lowercased(); let kind: V6Media.Kind
            if video.contains(ext) { kind = .video } else if image.contains(ext) { kind = .image } else { return nil }
            return V6Media(id: url.lastPathComponent, url: url, kind: kind, creatorID: assignments[url.lastPathComponent])
        }
    }
    func creator(_ media: V6Media) -> V6Creator? { guard let id = media.creatorID else { return nil }; return creators.first { $0.id == id } }
    func posts(_ creator: V6Creator) -> [V6Media] { media.filter { $0.creatorID == creator.id } }
}

final class V6Tabs: UITabBarController, UITabBarControllerDelegate, UIDocumentPickerDelegate {
    let store: V6Store; let feed: V6Feed; let library: V6Library; let creators: V6Creators
    init(store: V6Store) { self.store = store; feed = V6Feed(store: store); library = V6Library(store: store); creators = V6Creators(store: store); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); delegate = self
        let home = UINavigationController(rootViewController: feed); home.setNavigationBarHidden(true, animated: false)
        let lib = UINavigationController(rootViewController: library); let add = UIViewController(); let activity = UINavigationController(rootViewController: V6Activity(store: store)); let people = UINavigationController(rootViewController: creators)
        home.tabBarItem = UITabBarItem(title: "Home", image: UIImage(systemName: "house.fill"), tag: 0)
        lib.tabBarItem = UITabBarItem(title: "Library", image: UIImage(systemName: "square.grid.2x2.fill"), tag: 1)
        add.tabBarItem = UITabBarItem(title: "Add", image: UIImage(systemName: "plus.circle.fill"), tag: 2)
        activity.tabBarItem = UITabBarItem(title: "Activity", image: UIImage(systemName: "sparkles"), tag: 3)
        people.tabBarItem = UITabBarItem(title: "Creators", image: UIImage(systemName: "person.2.fill"), tag: 4)
        viewControllers = [home, lib, add, activity, people]
        let a = UITabBarAppearance(); a.configureWithOpaqueBackground(); a.backgroundColor = V6Theme.bg; a.stackedLayoutAppearance.selected.iconColor = V6Theme.peach; a.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: V6Theme.cream]; tabBar.standardAppearance = a; tabBar.scrollEdgeAppearance = a; tabBar.tintColor = V6Theme.peach
        store.changed = { [weak self] in self?.feed.reload(); self?.library.collectionView.reloadData(); self?.creators.collectionView.reloadData() }
    }
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if viewController === viewControllers?[2] { let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image, .movie], asCopy: true); picker.allowsMultipleSelection = true; picker.delegate = self; present(picker, animated: true); return false }; return true
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for source in urls { let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }; var dest = store.directory.appendingPathComponent(source.lastPathComponent); if FileManager.default.fileExists(atPath: dest.path) { dest = store.directory.appendingPathComponent(UUID().uuidString + "." + source.pathExtension) }; try? FileManager.default.copyItem(at: source, to: dest) }
        store.scan(); store.changed?()
    }
}

final class V6Surface: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var layerPlayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? { get { layerPlayer.player } set { layerPlayer.player = newValue } }
    override init(frame: CGRect) { super.init(frame: frame); layerPlayer.videoGravity = .resizeAspect; backgroundColor = .black }
    required init?(coder: NSCoder) { fatalError() }
}

final class V6Feed: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    let store: V6Store; let layout = UICollectionViewFlowLayout(); lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout); var items: [V6Media]
    init(store: V6Store) { self.store = store; items = store.media; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black; layout.scrollDirection = .vertical; layout.minimumLineSpacing = 0; collection.backgroundColor = .black; collection.isPagingEnabled = true; collection.alwaysBounceVertical = false; collection.showsVerticalScrollIndicator = false; collection.contentInsetAdjustmentBehavior = .never; collection.dataSource = self; collection.delegate = self; collection.register(V6FeedCell.self, forCellWithReuseIdentifier: "feed"); collection.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(collection); NSLayoutConstraint.activate([collection.leadingAnchor.constraint(equalTo: view.leadingAnchor), collection.trailingAnchor.constraint(equalTo: view.trailingAnchor), collection.topAnchor.constraint(equalTo: view.topAnchor), collection.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        let badge = UILabel(); badge.text = "  CORNBOX ✦  "; badge.font = .systemFont(ofSize: 13, weight: .black); badge.textColor = V6Theme.bg; badge.backgroundColor = V6Theme.cream; badge.layer.cornerRadius = 12; badge.clipsToBounds = true; badge.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(badge); NSLayoutConstraint.activate([badge.centerXAnchor.constraint(equalTo: view.centerXAnchor), badge.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8), badge.heightAnchor.constraint(equalToConstant: 28)])
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); if layout.itemSize != collection.bounds.size { layout.itemSize = collection.bounds.size; layout.invalidateLayout() } }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); playCenter() }
    func reload() { items = store.media; if isViewLoaded { collection.reloadData() } }
    func open(_ id: String) { items = store.media; collection.reloadData(); guard let i = items.firstIndex(where: { $0.id == id }) else { return }; collection.layoutIfNeeded(); collection.scrollToItem(at: IndexPath(item: i, section: 0), at: .top, animated: false); DispatchQueue.main.async { self.playCenter() } }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell { let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "feed", for: indexPath) as! V6FeedCell; let media = items[indexPath.item]; cell.set(media, creator: store.creator(media)); cell.creatorTap = { [weak self] in guard let self, let creator = self.store.creator(media) else { return }; self.navigationController?.pushViewController(V6Profile(store: self.store, creator: creator), animated: true) }; return cell }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) { (cell as? V6FeedCell)?.preparePlayer() }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) { (cell as? V6FeedCell)?.releasePlayer() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { collection.visibleCells.compactMap { $0 as? V6FeedCell }.forEach { $0.pause() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { playCenter() }
    private func playCenter() { let point = CGPoint(x: collection.bounds.midX, y: collection.contentOffset.y + collection.bounds.midY); guard let index = collection.indexPathForItem(at: point) else { return }; for cell in collection.visibleCells.compactMap({ $0 as? V6FeedCell }) { collection.indexPath(for: cell) == index ? cell.play() : cell.pause() } }
}

final class V6FeedCell: UICollectionViewCell {
    let surface = V6Surface(); let picture = UIImageView(); let avatar = UIButton(type: .system); let name = UILabel(); let handle = UILabel(); let slider = UISlider(); let time = UILabel(); var media: V6Media?; var player: AVPlayer?; var observer: Any?; var creatorTap: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .black
        for v in [surface, picture] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v); NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor), v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor)]) }; picture.contentMode = .scaleAspectFit
        avatar.translatesAutoresizingMaskIntoConstraints = false; avatar.layer.cornerRadius = 29; avatar.clipsToBounds = true; avatar.layer.borderWidth = 2; avatar.layer.borderColor = V6Theme.peach.cgColor; avatar.addTarget(self, action: #selector(openCreator), for: .touchUpInside)
        name.textColor = V6Theme.cream; name.font = .systemFont(ofSize: 17, weight: .black); handle.textColor = V6Theme.mint; handle.font = .systemFont(ofSize: 12, weight: .bold)
        let labels = UIStackView(arrangedSubviews: [name, handle]); labels.axis = .vertical; let identity = UIStackView(arrangedSubviews: [avatar, labels]); identity.axis = .horizontal; identity.spacing = 10; identity.alignment = .center; identity.translatesAutoresizingMaskIntoConstraints = false; addSubview(identity)
        slider.minimumTrackTintColor = V6Theme.peach; slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25); slider.thumbTintColor = V6Theme.cream; slider.translatesAutoresizingMaskIntoConstraints = false; slider.addTarget(self, action: #selector(scrub), for: .valueChanged); addSubview(slider)
        time.textColor = .white; time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold); time.translatesAutoresizingMaskIntoConstraints = false; addSubview(time)
        NSLayoutConstraint.activate([avatar.widthAnchor.constraint(equalToConstant: 58), avatar.heightAnchor.constraint(equalToConstant: 58), identity.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), identity.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -14), slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), slider.trailingAnchor.constraint(equalTo: time.leadingAnchor, constant: -8), slider.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16), time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), time.centerYAnchor.constraint(equalTo: slider.centerYAnchor), time.widthAnchor.constraint(equalToConstant: 82)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func prepareForReuse() { super.prepareForReuse(); releasePlayer(); picture.image = nil; creatorTap = nil }
    func set(_ media: V6Media, creator: V6Creator?) { self.media = media; name.text = creator?.name ?? "Unassigned"; handle.text = creator?.handle ?? ""; avatar.setImage(V6Images.avatar(creator, size: 120).withRenderingMode(.alwaysOriginal), for: .normal); if media.kind == .image { surface.isHidden = true; picture.isHidden = false; slider.isHidden = true; time.isHidden = true; picture.image = V6Images.down(media.url, max: 1800) } else { surface.isHidden = false; picture.isHidden = true; slider.isHidden = false; time.isHidden = false } }
    func preparePlayer() { guard let media, media.kind == .video, player == nil else { return }; let item = AVPlayerItem(asset: AVURLAsset(url: media.url)); item.preferredForwardBufferDuration = 3; let p = AVPlayer(playerItem: item); p.automaticallyWaitsToMinimizeStalling = true; player = p; surface.player = p; observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self, weak p] _ in guard let self, let p else { return }; let a = p.currentTime().seconds; let b = p.currentItem?.duration.seconds ?? 0; if a.isFinite && b.isFinite && b > 0 { self.slider.value = Float(a / b); self.time.text = String(format: "%d:%02d / %d:%02d", Int(a) / 60, Int(a) % 60, Int(b) / 60, Int(b) % 60) } } }
    func play() { preparePlayer(); player?.play() }; func pause() { player?.pause() }
    func releasePlayer() { if let observer, let player { player.removeTimeObserver(observer) }; observer = nil; player?.pause(); player?.replaceCurrentItem(with: nil); surface.player = nil; player = nil }
    @objc private func scrub() { guard let player, let d = player.currentItem?.duration.seconds, d.isFinite else { return }; player.seek(to: CMTime(seconds: Double(slider.value) * d, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    @objc private func openCreator() { creatorTap?() }
}

final class V6Creators: UICollectionViewController, UICollectionViewDelegateFlowLayout {
    let store: V6Store
    init(store: V6Store) { self.store = store; super.init(collectionViewLayout: UICollectionViewFlowLayout()); title = "Creators" }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); collectionView.backgroundColor = V6Theme.bg; collectionView.contentInset = UIEdgeInsets(top: 14, left: 14, bottom: 20, right: 14); collectionView.register(V6CreatorCell.self, forCellWithReuseIdentifier: "creator"); navigationController?.navigationBar.prefersLargeTitles = true; navigationController?.navigationBar.largeTitleTextAttributes = [.foregroundColor: V6Theme.cream] }
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { store.creators.count }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell { let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "creator", for: indexPath) as! V6CreatorCell; let creator = store.creators[indexPath.item]; cell.set(creator, count: store.posts(creator).count); return cell }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize { let w = (collectionView.bounds.width - 42) / 2; return CGSize(width: w, height: w * 1.18) }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { navigationController?.pushViewController(V6Profile(store: store, creator: store.creators[indexPath.item]), animated: true) }
}

final class V6CreatorCell: UICollectionViewCell {
    let avatar = UIImageView(); let name = UILabel(); let meta = UILabel()
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = V6Theme.card; layer.cornerRadius = 28; layer.borderWidth = 1.5; layer.borderColor = V6Theme.purple.cgColor; avatar.translatesAutoresizingMaskIntoConstraints = false; avatar.contentMode = .scaleAspectFill; avatar.clipsToBounds = true; avatar.layer.cornerRadius = 52; avatar.layer.borderWidth = 3; avatar.layer.borderColor = V6Theme.peach.cgColor; addSubview(avatar); name.textColor = V6Theme.cream; name.font = .systemFont(ofSize: 18, weight: .black); name.textAlignment = .center; meta.textColor = V6Theme.mint; meta.font = .systemFont(ofSize: 12, weight: .bold); meta.textAlignment = .center; let stack = UIStackView(arrangedSubviews: [name, meta]); stack.axis = .vertical; stack.spacing = 4; stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack); NSLayoutConstraint.activate([avatar.topAnchor.constraint(equalTo: topAnchor, constant: 18), avatar.centerXAnchor.constraint(equalTo: centerXAnchor), avatar.widthAnchor.constraint(equalToConstant: 104), avatar.heightAnchor.constraint(equalToConstant: 104), stack.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 12), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)]) }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ creator: V6Creator, count: Int) { avatar.image = V6Images.avatar(creator, size: 220); name.text = creator.name; meta.text = "\(creator.handle)  ✦  \(count) posts" }
}

final class V6Profile: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    let store: V6Store; let creator: V6Creator; var items: [V6Media]; let layout = UICollectionViewFlowLayout(); lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    init(store: V6Store, creator: V6Creator) { self.store = store; self.creator = creator; items = store.posts(creator); super.init(nibName: nil, bundle: nil); title = creator.name }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = V6Theme.bg; navigationController?.navigationBar.tintColor = V6Theme.cream; let avatar = UIImageView(image: V6Images.avatar(creator, size: 300)); avatar.translatesAutoresizingMaskIntoConstraints = false; avatar.contentMode = .scaleAspectFill; avatar.clipsToBounds = true; avatar.layer.cornerRadius = 62; avatar.layer.borderWidth = 4; avatar.layer.borderColor = V6Theme.peach.cgColor; let info = UILabel(); info.translatesAutoresizingMaskIntoConstraints = false; info.numberOfLines = 0; info.textColor = V6Theme.cream; info.font = .systemFont(ofSize: 15, weight: .semibold); info.text = "\(creator.name)\n\(creator.handle)\n\n\(creator.bio)\n\n✦ \(items.count) POSTS"; view.addSubview(avatar); view.addSubview(info); layout.minimumLineSpacing = 3; layout.minimumInteritemSpacing = 3; collection.backgroundColor = V6Theme.bg; collection.dataSource = self; collection.delegate = self; collection.register(V6MediaCell.self, forCellWithReuseIdentifier: "media"); collection.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(collection); NSLayoutConstraint.activate([avatar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18), avatar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16), avatar.widthAnchor.constraint(equalToConstant: 124), avatar.heightAnchor.constraint(equalToConstant: 124), info.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 16), info.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14), info.centerYAnchor.constraint(equalTo: avatar.centerYAnchor), collection.leadingAnchor.constraint(equalTo: view.leadingAnchor), collection.trailingAnchor.constraint(equalTo: view.trailingAnchor), collection.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 20), collection.bottomAnchor.constraint(equalTo: view.bottomAnchor)]) }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize { let w = (collectionView.bounds.width - 6) / 3; return CGSize(width: w, height: w * 1.35) }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell { let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "media", for: indexPath) as! V6MediaCell; cell.set(items[indexPath.item]); return cell }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { guard let tabs = tabBarController as? V6Tabs else { return }; tabs.feed.open(items[indexPath.item].id); tabs.selectedIndex = 0 }
}

final class V6Library: UICollectionViewController, UICollectionViewDelegateFlowLayout {
    let store: V6Store
    init(store: V6Store) { self.store = store; super.init(collectionViewLayout: UICollectionViewFlowLayout()); title = "Library" }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); collectionView.backgroundColor = V6Theme.bg; collectionView.register(V6MediaCell.self, forCellWithReuseIdentifier: "media"); navigationController?.navigationBar.prefersLargeTitles = true; navigationController?.navigationBar.largeTitleTextAttributes = [.foregroundColor: V6Theme.cream] }
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { store.media.count }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell { let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "media", for: indexPath) as! V6MediaCell; cell.set(store.media[indexPath.item]); return cell }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize { let w = (collectionView.bounds.width - 6) / 3; return CGSize(width: w, height: w * 1.42) }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { guard let tabs = tabBarController as? V6Tabs else { return }; tabs.feed.open(store.media[indexPath.item].id); tabs.selectedIndex = 0 }
}

final class V6MediaCell: UICollectionViewCell {
    let image = UIImageView()
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = V6Theme.card; image.contentMode = .scaleAspectFill; image.clipsToBounds = true; image.translatesAutoresizingMaskIntoConstraints = false; addSubview(image); NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: leadingAnchor), image.trailingAnchor.constraint(equalTo: trailingAnchor), image.topAnchor.constraint(equalTo: topAnchor), image.bottomAnchor.constraint(equalTo: bottomAnchor)]) }
    required init?(coder: NSCoder) { fatalError() }
    override func prepareForReuse() { super.prepareForReuse(); image.image = nil }
    func set(_ media: V6Media) { if media.kind == .image { image.image = V6Images.down(media.url, max: 500) } else { V6Thumb.shared.get(media.url) { [weak self] value in self?.image.image = value } } }
}

final class V6Activity: UIViewController {
    let store: V6Store
    init(store: V6Store) { self.store = store; super.init(nibName: nil, bundle: nil); title = "Activity" }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = V6Theme.bg; navigationController?.navigationBar.prefersLargeTitles = true; navigationController?.navigationBar.largeTitleTextAttributes = [.foregroundColor: V6Theme.cream]; let card = UILabel(); card.numberOfLines = 0; card.textAlignment = .center; card.textColor = V6Theme.cream; card.backgroundColor = V6Theme.card; card.layer.cornerRadius = 28; card.clipsToBounds = true; card.font = .systemFont(ofSize: 18, weight: .black); card.text = "✦ YOUR CORNBOX ✦\n\n\(store.media.count) pieces of media\n\(store.creators.count) creators\n\nYour collection has a pulse again."; card.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(card); NSLayoutConstraint.activate([card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), card.centerYAnchor.constraint(equalTo: view.centerYAnchor), card.heightAnchor.constraint(equalToConstant: 220)]) }
}

enum V6Images {
    static func avatar(_ creator: V6Creator?, size: CGFloat) -> UIImage { if let raw = creator?.photo, let comma = raw.firstIndex(of: ","), let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])), let image = UIImage(data: data) { return image }; let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)); return r.image { ctx in V6Theme.purple.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size)); let text = String((creator?.name ?? "?").prefix(1)).uppercased(); let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size * 0.4, weight: .black), .foregroundColor: V6Theme.cream]; let s = text.size(withAttributes: attrs); text.draw(at: CGPoint(x: (size - s.width) / 2, y: (size - s.height) / 2), withAttributes: attrs) } }
    static func down(_ url: URL, max: CGFloat) -> UIImage? { guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return UIImage(contentsOfFile: url.path) }; let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max]; guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return UIImage(contentsOfFile: url.path) }; return UIImage(cgImage: cg) }
}

final class V6Thumb {
    static let shared = V6Thumb(); let cache = NSCache<NSString, UIImage>(); let queue = DispatchQueue(label: "v6thumb", qos: .utility)
    func get(_ url: URL, completion: @escaping (UIImage?) -> Void) { let key = url.path as NSString; if let image = cache.object(forKey: key) { completion(image); return }; queue.async { let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width: 420, height: 720); let image = (try? g.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)).map { UIImage(cgImage: $0) }; if let image { self.cache.setObject(image, forKey: key) }; DispatchQueue.main.async { completion(image) } } }
}
