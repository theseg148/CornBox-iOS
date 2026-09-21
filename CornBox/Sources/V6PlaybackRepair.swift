import UIKit
import AVFoundation
import ObjectiveC.runtime

/// V6 playback reliability patch.
/// The original feed asks the centered cell to play before UICollectionView has
/// necessarily finished laying out its first visible cell.  The media itself is
/// valid (seeking works), but the player can remain permanently paused.
final class V6PlaybackRepair {
    static let shared = V6PlaybackRepair()
    private var timer: Timer?
    private weak var feed: V6Feed?

    static func install() {
        _ = shared
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audio.setActive(true)
        } catch {
            print("CornBox audio session warning: \(error)")
        }
    }

    func attach(to feed: V6Feed) {
        self.feed = feed
        timer?.invalidate()

        // Give UICollectionView one run-loop to finish its initial layout, then
        // keep the centered player honest. This also recovers after interrupted
        // seeks, tab changes, app foregrounding, and cells that became ready late.
        DispatchQueue.main.async { [weak self, weak feed] in
            guard let self, let feed else { return }
            feed.collection.layoutIfNeeded()
            self.playCentered(in: feed)
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self, weak feed] _ in
                guard let self, let feed, feed.viewIfLoaded?.window != nil else { return }
                self.playCentered(in: feed)
            }
        }
    }

    func detach(from feed: V6Feed) {
        guard self.feed === feed else { return }
        timer?.invalidate()
        timer = nil
        for case let cell as V6FeedCell in feed.collection.visibleCells {
            cell.pause()
        }
    }

    func playCentered(in feed: V6Feed) {
        guard !feed.collection.visibleCells.isEmpty else { return }

        let viewportCenterY = feed.collection.contentOffset.y + feed.collection.bounds.midY
        let candidates: [(V6FeedCell, CGFloat)] = feed.collection.visibleCells.compactMap { raw in
            guard let cell = raw as? V6FeedCell,
                  let path = feed.collection.indexPath(for: cell),
                  let attrs = feed.collection.layoutAttributesForItem(at: path) else { return nil }
            return (cell, abs(attrs.center.y - viewportCenterY))
        }
        guard let centered = candidates.min(by: { $0.1 < $1.1 })?.0 else { return }

        for case let cell as V6FeedCell in feed.collection.visibleCells {
            if cell === centered {
                guard cell.media?.kind == .video else { continue }
                cell.preparePlayer()
                if let item = cell.player?.currentItem, item.status == .failed {
                    print("CornBox AVPlayer item failed: \(String(describing: item.error))")
                    cell.releasePlayer()
                    cell.preparePlayer()
                }
                if cell.player?.rate == 0 {
                    cell.player?.playImmediately(atRate: 1.0)
                }
            } else {
                cell.pause()
            }
        }
    }
}

// Small lifecycle hooks kept outside the giant V6 source file.
extension V6Feed {
    @objc func cornboxPlaybackDidAppear() {
        V6PlaybackRepair.shared.attach(to: self)
    }

    @objc func cornboxPlaybackWillDisappear() {
        V6PlaybackRepair.shared.detach(from: self)
    }
}
