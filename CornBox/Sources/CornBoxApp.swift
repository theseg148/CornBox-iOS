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
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "cornbox")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
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
        private let copySemaphore = DispatchSemaphore(value: 3)
        private let destinationLock = NSLock()

        private lazy var rootDirectory: URL = {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return base.appendingPathComponent("CornBox", isDirectory: true)
        }()
        private lazy var mediaDirectory = rootDirectory.appendingPathComponent("media", isDirectory: true)
        private lazy var htmlURL = rootDirectory.appendingPathComponent("app.html")

        private let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
        private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"]

        func prepareAndLoadApp() {
            do {
                try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

                guard let bundledHTML = bundledHTMLURL() else {
                    showNativeError("Bundled HTML is missing. app.html was not found in the app bundle.")
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

        private func bundledHTMLURL() -> URL? {
            if let url = Bundle.main.url(forResource: "app", withExtension: "html") { return url }
            if let url = Bundle.main.url(forResource: "app", withExtension: "html", subdirectory: "Resources") { return url }

            let rootHTML = Bundle.main.urls(forResourcesWithExtension: "html", subdirectory: nil) ?? []
            if let app = rootHTML.first(where: { $0.lastPathComponent.lowercased() == "app.html" }) { return app }

            let resourceHTML = Bundle.main.urls(forResourcesWithExtension: "html", subdirectory: "Resources") ?? []
            return resourceHTML.first(where: { $0.lastPathComponent.lowercased() == "app.html" })
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            sendMediaListToWebView()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "cornbox",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            switch action {
            case "pickMedia": presentMediaSourceMenu()
            case "listMedia": sendMediaListToWebView()
            default: break
            }
        }

        private func presentMediaSourceMenu() {
            guard let presenter = topViewController() else { return }
            let sheet = UIAlertController(title: "Add media", message: "Large imports run in the background, so CornBox stays responsive.", preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Photos", style: .default) { [weak self] _ in self?.presentPhotoPicker() })
            sheet.addAction(UIAlertAction(title: "Files", style: .default) { [weak self] _ in self?.presentDocumentPicker() })
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

            let total = results.count
            sendImportProgress(completed: 0, total: total, finished: false)

            let group = DispatchGroup()
            let countLock = NSLock()
            var completed = 0
            var importedCount = 0

            for result in results {
                let provider = result.itemProvider
                let requestedType: UTType
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    requestedType = .movie
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    requestedType = .image
                } else {
                    countLock.lock()
                    completed += 1
                    let now = completed
                    countLock.unlock()
                    sendImportProgress(completed: now, total: total, finished: now == total)
                    continue
                }

                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: requestedType.identifier) { [weak self] sourceURL, _ in
                    defer { group.leave() }
                    guard let self else { return }

                    if let sourceURL {
                        self.copySemaphore.wait()
                        defer { self.copySemaphore.signal() }

                        let preferredName = self.preferredFilename(provider: provider, sourceURL: sourceURL, type: requestedType)
                        do {
                            _ = try self.copyIntoMediaDirectory(sourceURL, preferredName: preferredName)
                            countLock.lock()
                            importedCount += 1
                            countLock.unlock()
                        } catch {
                            print("CornBox import error: \(error)")
                        }
                    }

                    countLock.lock()
                    completed += 1
                    let now = completed
                    countLock.unlock()
                    self.sendImportProgress(completed: now, total: total, finished: now == total)
                }
            }

            group.notify(queue: .main) { [weak self] in
                if importedCount > 0 { self?.sendMediaListToWebView() }
                self?.sendImportProgress(completed: total, total: total, finished: true)
            }
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { return }
            let total = urls.count
            sendImportProgress(completed: 0, total: total, finished: false)

            let queue = OperationQueue()
            queue.name = "CornBox Media Import"
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = 3

            let countLock = NSLock()
            var completed = 0
            var imported = 0

            for sourceURL in urls {
                queue.addOperation { [weak self] in
                    guard let self else { return }
                    autoreleasepool {
                        let accessed = sourceURL.startAccessingSecurityScopedResource()
                        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
                        do {
                            _ = try self.copyIntoMediaDirectory(sourceURL, preferredName: sourceURL.lastPathComponent)
                            countLock.lock()
                            imported += 1
                            countLock.unlock()
                        } catch {
                            print("CornBox file import error: \(error)")
                        }

                        countLock.lock()
                        completed += 1
                        let now = completed
                        countLock.unlock()
                        self.sendImportProgress(completed: now, total: total, finished: now == total)
                    }
                }
            }

            queue.addBarrierBlock { [weak self] in
                DispatchQueue.main.async {
                    if imported > 0 { self?.sendMediaListToWebView() }
                    self?.sendImportProgress(completed: total, total: total, finished: true)
                }
            }
        }

        private func preferredFilename(provider: NSItemProvider, sourceURL: URL, type: UTType) -> String {
            var name = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceExtension = sourceURL.pathExtension
            if name == nil || name!.isEmpty { name = "media-\(UUID().uuidString)" }
            if (name! as NSString).pathExtension.isEmpty {
                let ext = !sourceExtension.isEmpty ? sourceExtension : (type.conforms(to: .movie) ? "mov" : "jpg")
                name! += ".\(ext)"
            }
            return name!
        }

        @discardableResult
        private func copyIntoMediaDirectory(_ sourceURL: URL, preferredName: String) throws -> URL {
            try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

            let tempURL = mediaDirectory.appendingPathComponent(".import-\(UUID().uuidString)")
            do {
                try fileManager.copyItem(at: sourceURL, to: tempURL)

                destinationLock.lock()
                defer { destinationLock.unlock() }
                let destination = uniqueDestination(for: sanitizeFilename(preferredName))
                try fileManager.moveItem(at: tempURL, to: destination)
                return destination
            } catch {
                try? fileManager.removeItem(at: tempURL)
                throw error
            }
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
                let next = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
                candidate = mediaDirectory.appendingPathComponent(next)
                index += 1
            }
            return candidate
        }

        private func sendImportProgress(completed: Int, total: Int, finished: Bool) {
            guard total > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let webView = self?.webView else { return }
                let finishedJS = finished ? "true" : "false"
                let script = "window.cornboxNativeImportProgress && window.cornboxNativeImportProgress(\(completed), \(total), \(finishedJS));"
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }

        private func sendMediaListToWebView() {
            guard let webView else { return }
            let items = mediaItems()
            guard let data = try? JSONSerialization.data(withJSONObject: items),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.cornboxNativeSetMedia && window.cornboxNativeSetMedia(\(json));") { _, error in
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
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }

            return sorted.compactMap { url in
                let ext = url.pathExtension.lowercased()
                let type: String
                if videoExtensions.contains(ext) { type = "video" }
                else if imageExtensions.contains(ext) { type = "image" }
                else { return nil }

                let relative = "media/" + url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
                return ["name": url.lastPathComponent, "url": relative, "type": type]
            }
        }

        private func topViewController() -> UIViewController? {
            guard var top = webView?.window?.rootViewController else { return nil }
            while let presented = top.presentedViewController { top = presented }
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
