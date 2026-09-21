import SwiftUI
import UIKit
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

struct RootViewV7: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { V7Tabs(store: .shared) }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

enum V7Style {
    static let bg = UIColor(red: 0.055, green: 0.045, blue: 0.09, alpha: 1)
    static let panel = UIColor(red: 0.11, green: 0.075, blue: 0.16, alpha: 1)
    static let purple = UIColor(red: 0.58, green: 0.35, blue: 1, alpha: 1)
    static let peach = UIColor(red: 1.0, green: 0.48, blue: 0.35, alpha: 1)
    static let cream = UIColor(red: 1.0, green: 0.94, blue: 0.82, alpha: 1)
    static let mint = UIColor(red: 0.4, green: 0.92, blue: 0.72, alpha: 1)
}

final class V7Settings {
    static let shared = V7Settings()
    var autoScroll: Bool { didSet { UserDefaults.standard.set(autoScroll, forKey: "v7.auto") } }
    var autoSeconds: Double { didSet { UserDefaults.standard.set(autoSeconds, forKey: "v7.seconds") } }
    var loopVideos: Bool { didSet { UserDefaults.standard.set(loopVideos, forKey: "v7.loop") } }
    private init() {
        autoScroll = UserDefaults.standard.bool(forKey: "v7.auto")
        let saved = UserDefaults.standard.double(forKey: "v7.seconds")
        autoSeconds = saved > 0 ? saved : 8
        loopVideos = UserDefaults.standard.object(forKey: "v7.loop") == nil ? true : UserDefaults.standard.bool(forKey: "v7.loop")
    }
}

final class V7Tabs: UITabBarController, UITabBarControllerDelegate, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    let store: V6Store
    let feed: V7Feed
    let library: V7Library
    let creators: V7Creators
    private let addPlaceholder = UIViewController()

    init(store: V6Store) {
        self.store = store
        feed = V7Feed(store: store)
        library = V7Library(store: store)
        creators = V7Creators(store: store)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        let home = UINavigationController(rootViewController: feed)
        home.setNavigationBarHidden(true, animated: false)
        let lib = UINavigationController(rootViewController: library)
        let activity = UINavigationController(rootViewController: V7Activity(store: store))
        let people = UINavigationController(rootViewController: creators)
        home.tabBarItem = UITabBarItem(title: "Home", image: UIImage(systemName: "house.fill"), tag: 0)
        lib.tabBarItem = UITabBarItem(title: "Library", image: UIImage(systemName: "square.grid.2x2.fill"), tag: 1)
        addPlaceholder.tabBarItem = UITabBarItem(title: "Add", image: UIImage(systemName: "plus.circle.fill"), tag: 2)
        activity.tabBarItem = UITabBarItem(title: "Activity", image: UIImage(systemName: "sparkles"), tag: 3)
        people.tabBarItem = UITabBarItem(title: "Creators", image: UIImage(systemName: "person.2.fill"), tag: 4)
        viewControllers = [home, lib, addPlaceholder, activity, people]
        let a = UITabBarAppearance(); a.configureWithOpaqueBackground(); a.backgroundColor = V7Style.bg
        a.stackedLayoutAppearance.selected.iconColor = V7Style.peach
        a.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: V7Style.cream]
        a.stackedLayoutAppearance.normal.iconColor = UIColor.white.withAlphaComponent(0.5)
        tabBar.standardAppearance = a; tabBar.scrollEdgeAppearance = a; tabBar.tintColor = V7Style.peach
        store.changed = { [weak self] in
            self?.feed.reload(); self?.library.reload(); self?.creators.reload()
        }
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if viewController === addPlaceholder { showAddMenu(); return false }
        return true
    }

    private func showAddMenu() {
        let sheet = UIAlertController(title: "Add to CornBox ✦", message: "Choose where your media comes from", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Photos & Videos", style: .default) { _ in self.openPhotos() })
        sheet.addAction(UIAlertAction(title: "Files", style: .default) { _ in self.openFiles() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func openPhotos() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos]); config.selectionLimit = 0
        let picker = PHPickerViewController(configuration: config); picker.delegate = self; present(picker, animated: true)
    }
    private func openFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image, .movie], asCopy: true)
        picker.allowsMultipleSelection = true; picker.delegate = self; present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { importURLs(urls) }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let group = DispatchGroup(); var urls: [URL] = []; let lock = NSLock()
        for result in results {
            let provider = result.itemProvider
            let type = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? UTType.movie.identifier : UTType.image.identifier
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                let ext = url.pathExtension.isEmpty ? (type == UTType.movie.identifier ? "mov" : "jpg") : url.pathExtension
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                if (try? FileManager.default.copyItem(at: url, to: temp)) != nil { lock.lock(); urls.append(temp); lock.unlock() }
            }
        }
        group.notify(queue: .main) { self.importURLs(urls) }
    }

    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for source in urls {
                autoreleasepool {
                    let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
                    let ext = source.pathExtension
                    var name = source.lastPathComponent
                    if name.isEmpty { name = UUID().uuidString + (ext.isEmpty ? "" : "." + ext) }
                    var dest = self.store.directory.appendingPathComponent(name); var n = 2
                    while FileManager.default.fileExists(atPath: dest.path) {
                        let stem = (name as NSString).deletingPathExtension
                        dest = self.store.directory.appendingPathComponent("\(stem) \(n)" + (ext.isEmpty ? "" : "." + ext)); n += 1
                    }
                    try? FileManager.default.copyItem(at: source, to: dest)
                }
            }
            DispatchQueue.main.async { self.store.scan(); self.store.changed?() }
        }
    }
}

final class V7Feed: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    let store: V6Store; let layout = UICollectionViewFlowLayout(); lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    var items: [V6Media]; var autoTimer: Timer?
    init(store: V6Store) { self.store = store; items = store.media; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        layout.scrollDirection = .vertical; layout.minimumLineSpacing = 0
        collection.backgroundColor = .black; collection.isPagingEnabled = true; collection.alwaysBounceVertical = false; collection.showsVerticalScrollIndicator = false; collection.contentInsetAdjustmentBehavior = .never
        collection.dataSource = self; collection.delegate = self; collection.register(V7FeedCell.self, forCellWithReuseIdentifier: "v7feed"); collection.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collection); NSLayoutConstraint.activate([collection.leadingAnchor.constraint(equalTo: view.leadingAnchor), collection.trailingAnchor.constraint(equalTo: view.trailingAnchor), collection.topAnchor.constraint(equalTo: view.topAnchor), collection.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        let logo = UILabel(); logo.text = "  CORNBOX ✦  "; logo.font = .systemFont(ofSize: 13, weight: .black); logo.textColor = V7Style.bg; logo.backgroundColor = V7Style.cream; logo.layer.cornerRadius = 13; logo.clipsToBounds = true; logo.translatesAutoresizingMaskIntoConstraints = false
        let gear = UIButton(type: .system); gear.setImage(UIImage(systemName: "gearshape.fill"), for: .normal); gear.tintColor = V7Style.cream; gear.backgroundColor = UIColor.black.withAlphaComponent(0.4); gear.layer.cornerRadius = 19; gear.translatesAutoresizingMaskIntoConstraints = false; gear.addTarget(self, action: #selector(settings), for: .touchUpInside)
        let shuffle = UIButton(type: .system); shuffle.setImage(UIImage(systemName: "shuffle"), for: .normal); shuffle.tintColor = V7Style.cream; shuffle.backgroundColor = UIColor.black.withAlphaComponent(0.4); shuffle.layer.cornerRadius = 19; shuffle.translatesAutoresizingMaskIntoConstraints = false; shuffle.addTarget(self, action: #selector(shuffleFeed), for: .touchUpInside)
        view.addSubview(logo); view.addSubview(gear); view.addSubview(shuffle)
        NSLayoutConstraint.activate([logo.centerXAnchor.constraint(equalTo: view.centerXAnchor), logo.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 7), logo.heightAnchor.constraint(equalToConstant: 28), shuffle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), shuffle.centerYAnchor.constraint(equalTo: logo.centerYAnchor), shuffle.widthAnchor.constraint(equalToConstant: 38), shuffle.heightAnchor.constraint(equalToConstant: 38), gear.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14), gear.centerYAnchor.constraint(equalTo: logo.centerYAnchor), gear.widthAnchor.constraint(equalToConstant: 38), gear.heightAnchor.constraint(equalToConstant: 38)])
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); if layout.itemSize != collection.bounds.size { layout.itemSize = collection.bounds.size; layout.invalidateLayout() } }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); playCenter(); resetAuto() }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); autoTimer?.invalidate(); visible().forEach { $0.pause(showOverlay: false) } }
    func reload() { items = store.media; if isViewLoaded { collection.reloadData() } }
    func open(_ id: String) { items = store.media; collection.reloadData(); guard let i = items.firstIndex(where: {$0.id == id}) else { return }; collection.layoutIfNeeded(); collection.scrollToItem(at: IndexPath(item: i, section: 0), at: .top, animated: false); DispatchQueue.main.async { self.playCenter() } }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell { let c = collectionView.dequeueReusableCell(withReuseIdentifier: "v7feed", for: indexPath) as! V7FeedCell; let m = items[indexPath.item]; c.configure(m, creator: store.creator(m)); c.creatorTap = { [weak self] in guard let self, let cr = self.store.creator(m) else { return }; self.navigationController?.pushViewController(V7Profile(store: self.store, creator: cr), animated: true) }; return c }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) { (cell as? V7FeedCell)?.preparePlayer() }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) { (cell as? V7FeedCell)?.releasePlayer() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { visible().forEach { $0.pause(showOverlay: false) }; autoTimer?.invalidate() }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { playCenter(); resetAuto() }
    private func visible() -> [V7FeedCell] { collection.visibleCells.compactMap {$0 as? V7FeedCell} }
    private func centerIndex() -> IndexPath? { collection.indexPathForItem(at: CGPoint(x: collection.bounds.midX, y: collection.contentOffset.y + collection.bounds.midY)) }
    private func playCenter() { guard let index = centerIndex() else { return }; for c in visible() { collection.indexPath(for: c) == index ? c.play() : c.pause(showOverlay: false) } }
    private func resetAuto() { autoTimer?.invalidate(); guard V7Settings.shared.autoScroll else { return }; autoTimer = Timer.scheduledTimer(withTimeInterval: V7Settings.shared.autoSeconds, repeats: false) { [weak self] _ in self?.advance() } }
    private func advance() { guard let idx = centerIndex(), idx.item + 1 < items.count else { return }; collection.scrollToItem(at: IndexPath(item: idx.item + 1, section: 0), at: .top, animated: true); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.playCenter(); self.resetAuto() } }
    @objc private func shuffleFeed() { items.shuffle(); collection.reloadData(); collection.setContentOffset(.zero, animated: false); DispatchQueue.main.async { self.playCenter(); self.resetAuto() } }
    @objc private func settings() { navigationController?.pushViewController(V7SettingsController(), animated: true) }
}

final class V7FeedCell: UICollectionViewCell {
    let surface = V6Surface(); let image = UIImageView(); let avatar = UIButton(type: .system); let name = UILabel(); let handle = UILabel(); let slider = UISlider(); let time = UILabel(); let pauseBadge = UIImageView(image: UIImage(systemName: "pause.fill"))
    var media: V6Media?; var player: AVPlayer?; var observer: Any?; var endObserver: NSObjectProtocol?; var creatorTap: (() -> Void)?; var userPaused = false
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .black
        surface.translatesAutoresizingMaskIntoConstraints = false; image.translatesAutoresizingMaskIntoConstraints = false; image.contentMode = .scaleAspectFit; image.backgroundColor = .black
        addSubview(surface); addSubview(image); for v in [surface, image] { NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor), v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor)]) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(togglePlayback)); addGestureRecognizer(tap)
        pauseBadge.tintColor = .white; pauseBadge.backgroundColor = UIColor.black.withAlphaComponent(0.55); pauseBadge.contentMode = .center; pauseBadge.layer.cornerRadius = 34; pauseBadge.clipsToBounds = true; pauseBadge.translatesAutoresizingMaskIntoConstraints = false; pauseBadge.alpha = 0; addSubview(pauseBadge)
        avatar.translatesAutoresizingMaskIntoConstraints = false; avatar.layer.cornerRadius = 28; avatar.clipsToBounds = true; avatar.layer.borderWidth = 2.5; avatar.layer.borderColor = V7Style.peach.cgColor; avatar.addTarget(self, action: #selector(openCreator), for: .touchUpInside)
        name.textColor = V7Style.cream; name.font = .systemFont(ofSize: 17, weight: .black); handle.textColor = V7Style.mint; handle.font = .systemFont(ofSize: 12, weight: .bold)
        let labels = UIStackView(arrangedSubviews: [name, handle]); labels.axis = .vertical; labels.spacing = 2
        let identity = UIStackView(arrangedSubviews: [avatar, labels]); identity.axis = .horizontal; identity.spacing = 10; identity.alignment = .center; identity.translatesAutoresizingMaskIntoConstraints = false; addSubview(identity)
        slider.minimumTrackTintColor = V7Style.peach; slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25); slider.thumbTintColor = V7Style.cream; slider.translatesAutoresizingMaskIntoConstraints = false; slider.addTarget(self, action: #selector(scrub), for: .valueChanged); addSubview(slider)
        time.textColor = .white; time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold); time.translatesAutoresizingMaskIntoConstraints = false; addSubview(time)
        NSLayoutConstraint.activate([pauseBadge.centerXAnchor.constraint(equalTo: centerXAnchor), pauseBadge.centerYAnchor.constraint(equalTo: centerYAnchor), pauseBadge.widthAnchor.constraint(equalToConstant: 68), pauseBadge.heightAnchor.constraint(equalToConstant: 68), avatar.widthAnchor.constraint(equalToConstant: 56), avatar.heightAnchor.constraint(equalToConstant: 56), identity.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), identity.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -14), slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), slider.trailingAnchor.constraint(equalTo: time.leadingAnchor, constant: -8), slider.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16), time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), time.centerYAnchor.constraint(equalTo: slider.centerYAnchor), time.widthAnchor.constraint(equalToConstant: 82)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func prepareForReuse() { super.prepareForReuse(); releasePlayer(); image.image = nil; creatorTap = nil; userPaused = false; pauseBadge.alpha = 0 }
    func configure(_ m: V6Media, creator: V6Creator?) { media = m; name.text = creator?.name ?? "Unassigned"; handle.text = creator?.handle ?? ""; avatar.setImage(V6Images.avatar(creator, size: 120).withRenderingMode(.alwaysOriginal), for: .normal); let video = m.kind == .video; surface.isHidden = !video; image.isHidden = video; slider.isHidden = !video; time.isHidden = !video; if !video { image.image = V6Images.down(m.url, max: 1800) } }
    func preparePlayer() { guard let m = media, m.kind == .video, player == nil else { return }; let item = AVPlayerItem(url: m.url); let p = AVPlayer(playerItem: item); p.automaticallyWaitsToMinimizeStalling = false; surface.player = p; player = p; observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self, weak p] _ in guard let self, let p else { return }; let a = p.currentTime().seconds, b = p.currentItem?.duration.seconds ?? 0; if a.isFinite && b.isFinite && b > 0 { if !self.slider.isTracking { self.slider.value = Float(a / b) }; self.time.text = String(format: "%d:%02d / %d:%02d", Int(a)/60, Int(a)%60, Int(b)/60, Int(b)%60) } }; endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in guard let self else { return }; if V7Settings.shared.loopVideos { self.player?.seek(to: .zero); self.player?.playImmediately(atRate: 1) } } }
    func play() { preparePlayer(); guard !userPaused else { return }; player?.playImmediately(atRate: 1); pauseBadge.alpha = 0 }
    func pause(showOverlay: Bool) { player?.pause(); if showOverlay { pauseBadge.alpha = 1 } }
    func releasePlayer() { if let observer, let player { player.removeTimeObserver(observer) }; if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; observer = nil; endObserver = nil; player?.pause(); player?.replaceCurrentItem(with: nil); surface.player = nil; player = nil }
    @objc private func togglePlayback() { guard media?.kind == .video else { return }; preparePlayer(); if player?.rate ?? 0 > 0 { userPaused = true; pause(showOverlay: true) } else { userPaused = false; player?.playImmediately(atRate: 1); UIView.animate(withDuration: 0.2) { self.pauseBadge.alpha = 0 } } }
    @objc private func scrub() { guard let p = player, let d = p.currentItem?.duration.seconds, d.isFinite else { return }; p.seek(to: CMTime(seconds: Double(slider.value) * d, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    @objc private func openCreator() { creatorTap?() }
}

final class V7Library: UICollectionViewController, UICollectionViewDelegateFlowLayout {
    let store: V6Store
    init(store: V6Store) { self.store = store; super.init(collectionViewLayout: UICollectionViewFlowLayout()); title = "Library" }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); collectionView.backgroundColor = V7Style.bg; collectionView.contentInset = UIEdgeInsets(top: 10, left: 8, bottom: 20, right: 8); collectionView.register(V7MediaCell.self, forCellWithReuseIdentifier: "media"); navigationController?.navigationBar.prefersLargeTitles = true; navigationController?.navigationBar.largeTitleTextAttributes = [.foregroundColor: V7Style.cream]; navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "shuffle"), style: .plain, target: self, action: #selector(shuffle)) }
    func reload() { if isViewLoaded { collectionView.reloadData() } }
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { store.media.count }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell { let c = collectionView.dequeueReusableCell(withReuseIdentifier: "media", for: indexPath) as! V7MediaCell; let m = store.media[indexPath.item]; c.configure(m, creator: store.creator(m)); return c }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize { let w = floor((collectionView.bounds.width - 20) / 3); return CGSize(width: w, height: w * 1.45) }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat { 2 }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat { 2 }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { guard let tabs = tabBarController as? V7Tabs else { return }; tabs.feed.open(store.media[indexPath.item].id); tabs.selectedIndex = 0 }
    @objc private func shuffle() { guard let tabs = tabBarController as? V7Tabs else { return }; tabs.feed.items.shuffle(); tabs.feed.collection.reloadData(); tabs.selectedIndex = 0 }
}

final class V7MediaCell: UICollectionViewCell {
    let preview = UIImageView(); let label = UILabel(); let play = UIImageView(image: UIImage(systemName: "play.circle.fill")); var token = UUID()
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = V7Style.panel; layer.cornerRadius = 12; clipsToBounds = true; preview.contentMode = .scaleAspectFit; preview.backgroundColor = .black; preview.translatesAutoresizingMaskIntoConstraints = false; label.textColor = V7Style.cream; label.font = .systemFont(ofSize: 10, weight: .bold); label.backgroundColor = UIColor.black.withAlphaComponent(0.65); label.translatesAutoresizingMaskIntoConstraints = false; play.tintColor = .white; play.translatesAutoresizingMaskIntoConstraints = false; addSubview(preview); addSubview(label); addSubview(play); NSLayoutConstraint.activate([preview.leadingAnchor.constraint(equalTo: leadingAnchor), preview.trailingAnchor.constraint(equalTo: trailingAnchor), preview.topAnchor.constraint(equalTo: topAnchor), preview.bottomAnchor.constraint(equalTo: bottomAnchor), label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5), label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6), label.heightAnchor.constraint(equalToConstant: 20), play.centerXAnchor.constraint(equalTo: centerXAnchor), play.centerYAnchor.constraint(equalTo: centerYAnchor), play.widthAnchor.constraint(equalToConstant: 30), play.heightAnchor.constraint(equalToConstant: 30)]) }
    required init?(coder: NSCoder) { fatalError() }
    override func prepareForReuse() { super.prepareForReuse(); token = UUID(); preview.image = nil }
    func configure(_ m: V6Media, creator: V6Creator?) { label.text = "  \(creator?.name ?? "Unassigned")  "; play.isHidden = m.kind != .video; if m.kind == .image { preview.image = V6Images.down(m.url, max: 600) } else { let t = UUID(); token = t; V7Thumbs.shared.get(m.url) { [weak self] img in guard let self, self.token == t else { return }; self.preview.image = img } } }
}

final class V7Thumbs {
    static let shared = V7Thumbs(); let cache = NSCache<NSString, UIImage>(); let queue = DispatchQueue(label: "cornbox.v7.thumbs", qos: .utility)
    func get(_ url: URL, completion: @escaping (UIImage?) -> Void) { let key = url.path as NSString; if let i = cache.object(forKey: key) { completion(i); return }; queue.async { let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width: 600, height: 900); let cg = try? g.copyCGImage(at: CMTime(seconds: 0.15, preferredTimescale: 600), actualTime: nil); let img = cg.map(UIImage.init(cgImage:)); if let img { self.cache.setObject(img, forKey: key) }; DispatchQueue.main.async { completion(img) } } }
}

final class V7Creators: UICollectionViewController, UICollectionViewDelegateFlowLayout {
    let store: V6Store
    init(store: V6Store) { self.store = store; super.init(collectionViewLayout: UICollectionViewFlowLayout()); title = "Creators" }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); collectionView.backgroundColor = V7Style.bg; collectionView.contentInset = UIEdgeInsets(top: 14, left: 14, bottom: 20, right: 14); collectionView.register(V7CreatorCard.self, forCellWithReuseIdentifier: "creator"); navigationController?.navigationBar.prefersLargeTitles = true; navigationController?.navigationBar.largeTitleTextAttributes = [.foregroundColor: V7Style.cream] }
    func reload() { if isViewLoaded { collectionView.reloadData() } }
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { store.creators.count }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell { let c = collectionView.dequeueReusableCell(withReuseIdentifier: "creator", for: indexPath) as! V7CreatorCard; let cr = store.creators[indexPath.item]; c.configure(cr, count: store.posts(cr).count); return c }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize { CGSize(width: collectionView.bounds.width - 28, height: 112) }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { navigationController?.pushViewController(V7Profile(store: store, creator: store.creators[indexPath.item]), animated: true) }
}

final class V7CreatorCard: UICollectionViewCell {
    let avatar = UIImageView(); let name = UILabel(); let handle = UILabel(); let count = UILabel()
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = V7Style.panel; layer.cornerRadius = 24; layer.borderWidth = 1; layer.borderColor = V7Style.purple.withAlphaComponent(0.5).cgColor; avatar.contentMode = .scaleAspectFill; avatar.layer.cornerRadius = 38; avatar.clipsToBounds = true; avatar.layer.borderWidth = 3; avatar.layer.borderColor = V7Style.peach.cgColor; avatar.translatesAutoresizingMaskIntoConstraints = false; name.textColor = V7Style.cream; name.font = .systemFont(ofSize: 20, weight: .black); handle.textColor = V7Style.mint; handle.font = .systemFont(ofSize: 13, weight: .bold); count.textColor = UIColor.white.withAlphaComponent(0.65); count.font = .systemFont(ofSize: 12, weight: .semibold); let text = UIStackView(arrangedSubviews: [name, handle, count]); text.axis = .vertical; text.spacing = 4; text.translatesAutoresizingMaskIntoConstraints = false; addSubview(avatar); addSubview(text); NSLayoutConstraint.activate([avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), avatar.centerYAnchor.constraint(equalTo: centerYAnchor), avatar.widthAnchor.constraint(equalToConstant: 76), avatar.heightAnchor.constraint(equalToConstant: 76), text.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 16), text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), text.centerYAnchor.constraint(equalTo: centerYAnchor)]) }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ c: V6Creator, count n: Int) { avatar.image = V6Images.avatar(c, size: 180); name.text = c.name; handle.text = c.handle; count.text = "\(n) post\(n == 1 ? "" : "s")  ✦  View profile →" }
}

final class V7Profile: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    let store: V6Store; let creator: V6Creator; let header = UIView(); let avatar = UIImageView(); let name = UILabel(); let handle = UILabel(); let bio = UILabel(); let count = UILabel(); let collection: UICollectionView
    init(store: V6Store, creator: V6Creator) { self.store = store; self.creator = creator; collection = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout()); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); title = creator.name; view.backgroundColor = V7Style.bg; header.backgroundColor = V7Style.panel; header.layer.cornerRadius = 28; header.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(header); avatar.image = V6Images.avatar(creator, size: 260); avatar.layer.cornerRadius = 55; avatar.clipsToBounds = true; avatar.layer.borderWidth = 4; avatar.layer.borderColor = V7Style.peach.cgColor; avatar.translatesAutoresizingMaskIntoConstraints = false; name.text = creator.name; name.textColor = V7Style.cream; name.font = .systemFont(ofSize: 27, weight: .black); handle.text = creator.handle; handle.textColor = V7Style.mint; handle.font = .systemFont(ofSize: 14, weight: .bold); bio.text = creator.bio; bio.textColor = UIColor.white.withAlphaComponent(0.82); bio.font = .systemFont(ofSize: 14); bio.numberOfLines = 3; count.text = "\(store.posts(creator).count) POSTS  ✦"; count.textColor = V7Style.peach; count.font = .systemFont(ofSize: 12, weight: .black); let text = UIStackView(arrangedSubviews: [name, handle, bio, count]); text.axis = .vertical; text.spacing = 6; text.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(avatar); header.addSubview(text); collection.backgroundColor = V7Style.bg; collection.dataSource = self; collection.delegate = self; collection.register(V7MediaCell.self, forCellWithReuseIdentifier: "media"); collection.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(collection); NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10), header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14), header.heightAnchor.constraint(equalToConstant: 160), avatar.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18), avatar.centerYAnchor.constraint(equalTo: header.centerYAnchor), avatar.widthAnchor.constraint(equalToConstant: 110), avatar.heightAnchor.constraint(equalToConstant: 110), text.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 16), text.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16), text.centerYAnchor.constraint(equalTo: header.centerYAnchor), collection.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), collection.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), collection.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), collection.bottomAnchor.constraint(equalTo: view.bottomAnchor)]) }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { store.posts(creator).count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell { let c = collectionView.dequeueReusableCell(withReuseIdentifier: "media", for: indexPath) as! V7MediaCell; c.configure(store.posts(creator)[indexPath.item], creator: creator); return c }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize { let w = floor((collectionView.bounds.width - 4) / 3); return CGSize(width: w, height: w * 1.45) }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat { 2 }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat { 2 }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { guard let tabs = tabBarController as? V7Tabs else { return }; tabs.feed.open(store.posts(creator)[indexPath.item].id); tabs.selectedIndex = 0 }
}

final class V7SettingsController: UITableViewController {
    let s = V7Settings.shared
    init() { super.init(style: .insetGrouped); title = "Settings ✦" }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = V7Style.bg }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 3 : 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Feed" : "About" }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell { let c = UITableViewCell(style: .value1, reuseIdentifier: nil); c.backgroundColor = V7Style.panel; c.textLabel?.textColor = V7Style.cream; c.detailTextLabel?.textColor = V7Style.mint; if indexPath.section == 1 { c.textLabel?.text = "CornBox"; c.detailTextLabel?.text = "Native V7 ✦"; c.selectionStyle = .none; return c }; if indexPath.row == 0 { c.textLabel?.text = "Auto-scroll"; let sw = UISwitch(); sw.isOn = s.autoScroll; sw.addTarget(self, action: #selector(autoChanged(_:)), for: .valueChanged); c.accessoryView = sw } else if indexPath.row == 1 { c.textLabel?.text = "Auto-scroll delay"; c.detailTextLabel?.text = "\(Int(s.autoSeconds)) sec"; c.accessoryType = .disclosureIndicator } else { c.textLabel?.text = "Loop videos"; let sw = UISwitch(); sw.isOn = s.loopVideos; sw.addTarget(self, action: #selector(loopChanged(_:)), for: .valueChanged); c.accessoryView = sw }; return c }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { tableView.deselectRow(at: indexPath, animated: true); guard indexPath.section == 0, indexPath.row == 1 else { return }; let a = UIAlertController(title: "Auto-scroll delay", message: nil, preferredStyle: .actionSheet); for n in [3,5,8,10,15,20] { a.addAction(UIAlertAction(title: "\(n) seconds", style: .default) { _ in self.s.autoSeconds = Double(n); self.tableView.reloadData() }) }; a.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(a, animated: true) }
    @objc private func autoChanged(_ sw: UISwitch) { s.autoScroll = sw.isOn }
    @objc private func loopChanged(_ sw: UISwitch) { s.loopVideos = sw.isOn }
}

final class V7Activity: UITableViewController {
    let store: V6Store
    init(store: V6Store) { self.store = store; super.init(style: .insetGrouped); title = "Activity" }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = V7Style.bg; navigationController?.navigationBar.prefersLargeTitles = true; navigationController?.navigationBar.largeTitleTextAttributes = [.foregroundColor: V7Style.cream] }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 3 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell { let c = UITableViewCell(style: .subtitle, reuseIdentifier: nil); c.backgroundColor = V7Style.panel; c.textLabel?.textColor = V7Style.cream; c.detailTextLabel?.textColor = UIColor.white.withAlphaComponent(0.6); c.selectionStyle = .none; if indexPath.row == 0 { c.textLabel?.text = "\(store.media.count) pieces of media"; c.detailTextLabel?.text = "Your CornBox library"; c.imageView?.image = UIImage(systemName: "film.stack") } else if indexPath.row == 1 { c.textLabel?.text = "\(store.creators.count) creators"; c.detailTextLabel?.text = "Profiles in your collection"; c.imageView?.image = UIImage(systemName: "person.2.fill") } else { c.textLabel?.text = "CornBox is local"; c.detailTextLabel?.text = "Your media stays on this iPhone"; c.imageView?.image = UIImage(systemName: "iphone") }; return c }
}
