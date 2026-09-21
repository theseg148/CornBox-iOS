import UIKit
import AVFoundation

/// Reliability layer for the V6 native feed.
/// V6 could create and seek AVPlayers correctly, but its first `playCenter()`
/// often ran before UICollectionView had a centered cell. Nothing later forced
/// playback, leaving a perfectly seekable player sitting at rate 0.
final class V6PlaybackRepair {
    static let shared = V6PlaybackRepair()
    private var timer: Timer?
    private weak var feed: V6Feed?
    private var installed = false

    static func install() { shared.installOnce() }

    private func installOnce() {
        guard !installed else { return }
        installed = true

        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audio.setActive(true)
        } catch {
            print("CornBox audio session warning: \(error)")
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.discoverFeed() }

        // SwiftUI's window/controller tree is not guaranteed to exist during
        // App.init, so discover it after launch and again shortly afterwards.
        DispatchQueue.main.async { [weak self] in self?.discoverFeed() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.discoverFeed() }
    }

    private func discoverFeed() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        for window in windows where !window.isHidden {
            if let found = findFeed(in: window.rootViewController) {
                attach(to: found)
                return
            }
        }
    }

    private func findFeed(in controller: UIViewController?) -> V6Feed? {
        guard let controller else { return nil }
        if let feed = controller as? V6Feed { return feed }
        if let nav = controller as? UINavigationController {
            for child in nav.viewControllers {
                if let feed = findFeed(in: child) { return feed }
            }
        }
        if let tabs = controller as? UITabBarController {
            for child in tabs.viewControllers ?? [] {
                if let feed = findFeed(in: child) { return feed }
            }
        }
        for child in controller.children {
            if let feed = findFeed(in: child) { return feed }
        }
        return nil
    }

    func attach(to feed: V6Feed) {
        self.feed = feed
        timer?.invalidate()
        feed.collection.layoutIfNeeded()

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak feed] _ in
            guard let self, let feed else { return }
            guard feed.tabBarController?.selectedIndex == 0,
                  feed.viewIfLoaded?.window != nil else {
                for case let cell as V6FeedCell in feed.collection.visibleCells { cell.pause() }
                return
            }
            self.playCentered(in: feed)
        }
        timer?.fire()
    }

    private func playCentered(in feed: V6Feed) {
        guard !feed.collection.isDragging,
              !feed.collection.isDecelerating,
              !feed.collection.visibleCells.isEmpty else { return }

        let viewportCenterY = feed.collection.contentOffset.y + feed.collection.bounds.midY
        let candidates: [(V6FeedCell, CGFloat)] = feed.collection.visibleCells.compactMap { raw in
            guard let cell = raw as? V6FeedCell,
                  let path = feed.collection.indexPath(for: cell),
                  let attrs = feed.collection.layoutAttributesForItem(at: path) else { return nil }
            return (cell, abs(attrs.center.y - viewportCenterY))
        }
        guard let centered = candidates.min(by: { $0.1 < $1.1 })?.0 else { return }

        for case let cell as V6FeedCell in feed.collection.visibleCells {
            guard cell === centered else {
                cell.pause()
                continue
            }
            guard cell.media?.kind == .video else { continue }

            cell.preparePlayer()
            guard let player = cell.player else { continue }

            if let item = player.currentItem, item.status == .failed {
                print("CornBox AVPlayer item failed: \(String(describing: item.error))")
                cell.releasePlayer()
                cell.preparePlayer()
            }

            // Local files do not need network-style waiting. `playImmediately`
            // makes rate=1 explicit and fixes the seekable-but-never-playing state.
            if player.rate == 0 {
                player.automaticallyWaitsToMinimizeStalling = false
                player.playImmediately(atRate: 1.0)
            }
        }
    }
}
