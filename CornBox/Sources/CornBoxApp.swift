import SwiftUI
import WebKit
import PhotosUI
import UniformTypeIdentifiers

@main
struct CornBoxApp: App {
    var body: some Scene {
        WindowGroup {
            CornBoxWebView()
                .ignoresSafeArea()
        }
    }
}

struct CornBoxWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "cornbox")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.prepareAndLoadApp()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "cornbox")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
        weak var webView: WKWebView?

        private let fileManager = FileManager.default
        private lazy var rootDirectory: URL = {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return base.appendingPathComponent("CornBox", isDirectory: true)
        }()
        private lazy var mediaDirectory: URL = rootDirectory.appendingPathComponent("media", isDirectory: true)
        private lazy var htmlURL: URL = rootDirectory.appendingPathComponent("index.html")

        private let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
        private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"]

        func prepareAndLoadApp() {
            do {
                try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
                guard let bundledHTML = Bundle.main.url(forResource: "app", withExtension: "html") else {
                    showNativeError("Bundled app.html is missing.")
                    return
                }

                if fileManager.fileExists(atPath: htmlURL.path) {
                    try fileManager.removeItem(at: htmlURL)
                }
                try fileManager.copyItem(at: bundledHTML, to: htmlURL)

                webView?.loadFileURL(htmlURL, allowingReadAccessTo: rootDirectory)
            } catch {
                showNativeError("Could not prepare CornBox: \(error.localizedDescription)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            sendMediaListToWebView()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "cornbox" else { return }
            guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }

            switch action {
            case "pickMedia":
                presentMediaSourceMenu()
            case "listMedia":
                sendMediaListToWebView()
            default:
                break
            }
        }

        private func presentMediaSourceMenu() {
            guard let presenter = topViewController() else { return }

            let sheet = UIAlertController(title: "Add media", message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Photos", style: .default) { [weak self] _ in
                self?.presentPhotoPicker()
            })
            sheet.addAction(UIAlertAction(title: "Files", style: .default) { [weak self] _ in
                self?.presentDocumentPicker()
            })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

            if let popover = sheet.popoverPresentationController {
                popover.sourceView = webView
                popover.sourceRect = CGRect(x: webView?.bounds.midX ?? 0, y: webView?.bounds.maxY ?? 0, width: 1, height: 1)
            }
            presenter.present(sheet, animated: true)
        }

        private func presentPhotoPicker() {
            var configuration = PHPickerConfiguration(photoLibrary: .shared())
            configuration.filter = .any(of: [.images, .videos])
            configuration.selectionLimit = 0
            configuration.preferredAssetRepresentationMode = .current

            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            topViewController()?.present(picker, animated: true)
        }

        private func presentDocumentPicker() {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image, .movie], asCopy: true)
            picker.allowsMultipleSelection = true
            picker.delegate = self
            topViewController()?.present(picker, animated: true)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }

            let group = DispatchGroup()
            let lock = NSLock()
            var importedCount = 0

            for result in results {
                let provider = result.itemProvider
                let requestedType: UTType
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    requestedType = .movie
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    requestedType = .image
                } else {
                    continue
                }

                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: requestedType.identifier) { [weak self] sourceURL, _ in
                    defer { group.leave() }
                    guard let self, let sourceURL else { return }
                    let preferredName = self.preferredFilename(provider: provider, sourceURL: sourceURL, type: requestedType)
                    do {
                        _ = try self.copyIntoMediaDirectory(sourceURL, preferredName: preferredName)
                        lock.lock(); importedCount += 1; lock.unlock()
                    } catch {
                        print("CornBox import error: \(error)")
                    }
                }
            }

            group.notify(queue: .main) { [weak self] in
                guard importedCount > 0 else { return }
                self?.sendMediaListToWebView()
            }
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            var imported = 0
            for sourceURL in urls {
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed { sourceURL.stopAccessingSecurityScopedResource() }
                }

                do {
                    _ = try copyIntoMediaDirectory(sourceURL, preferredName: sourceURL.lastPathComponent)
                    imported += 1
                } catch {
                    print("CornBox file import error: \(error)")
                }
            }
            if imported > 0 {
                sendMediaListToWebView()
            }
        }

        private func preferredFilename(provider: NSItemProvider, sourceURL: URL, type: UTType) -> String {
            var name = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceExtension = sourceURL.pathExtension

            if name == nil || name!.isEmpty {
                name = "media-\(UUID().uuidString)"
            }

            if (name! as NSString).pathExtension.isEmpty {
                let fallbackExtension: String
                if !sourceExtension.isEmpty {
                    fallbackExtension = sourceExtension
                } else if type.conforms(to: .movie) {
                    fallbackExtension = "mov"
                } else {
                    fallbackExtension = "jpg"
                }
                name! += ".\(fallbackExtension)"
            }
            return name!
        }

        @discardableResult
        private func copyIntoMediaDirectory(_ sourceURL: URL, preferredName: String) throws -> URL {
            try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

            let cleaned = sanitizeFilename(preferredName)
            let destination = uniqueDestination(for: cleaned)
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        }

        private func sanitizeFilename(_ filename: String) -> String {
            let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
            let pieces = filename.components(separatedBy: invalid).filter { !$0.isEmpty }
            let joined = pieces.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? "media-\(UUID().uuidString)" : joined
        }

        private func uniqueDestination(for filename: String) -> URL {
            var candidate = mediaDirectory.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

            let stem = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            var index = 2
            while fileManager.fileExists(atPath: candidate.path) {
                let nextName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
                candidate = mediaDirectory.appendingPathComponent(nextName)
                index += 1
            }
            return candidate
        }

        private func sendMediaListToWebView() {
            guard let webView else { return }
            let items = mediaItems()
            guard let data = try? JSONSerialization.data(withJSONObject: items),
                  let json = String(data: data, encoding: .utf8) else { return }

            let script = "window.cornboxNativeSetMedia && window.cornboxNativeSetMedia(\(json));"
            webView.evaluateJavaScript(script) { _, error in
                if let error { print("CornBox JS bridge error: \(error)") }
            }
        }

        private func mediaItems() -> [[String: String]] {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: mediaDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            let sorted = urls.sorted {
                let l = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }

            return sorted.compactMap { url in
                let ext = url.pathExtension.lowercased()
                let type: String
                if videoExtensions.contains(ext) {
                    type = "video"
                } else if imageExtensions.contains(ext) {
                    type = "image"
                } else {
                    return nil
                }

                let relative = "media/" + url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
                return ["name": url.lastPathComponent, "url": relative, "type": type]
            }
        }

        private func topViewController() -> UIViewController? {
            guard var top = webView?.window?.rootViewController else { return nil }
            while let presented = top.presentedViewController {
                top = presented
            }
            return top
        }

        private func showNativeError(_ message: String) {
            DispatchQueue.main.async { [weak self] in
                guard let presenter = self?.topViewController() else {
                    print(message)
                    return
                }
                let alert = UIAlertController(title: "CornBox", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                presenter.present(alert, animated: true)
            }
        }
    }
}
