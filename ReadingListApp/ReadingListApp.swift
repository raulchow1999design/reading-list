import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - WebView Wrapper
struct WebView: NSViewRepresentable {
    let htmlName: String
    @Binding var droppedFileURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Allow file access
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // Disable elastic scrolling (bounce)
        webView.enclosingScrollView?.horizontalScrollElasticity = .none
        webView.enclosingScrollView?.verticalScrollElasticity = .none

        // Register for drag & drop
        webView.registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("com.adobe.pdf"),
            NSPasteboard.PasteboardType("org.openxmlformats.wordprocessingml.document")
        ])

        // Load local HTML
        if let htmlPath = Bundle.main.path(forResource: htmlName, ofType: nil) {
            let url = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Handle file drops
        if let fileURL = droppedFileURL {
            injectFileIntoWebView(webView, fileURL: fileURL)
            DispatchQueue.main.async {
                droppedFileURL = nil
            }
        }
    }

    private func injectFileIntoWebView(_ webView: WKWebView, fileURL: URL) {
        // Read the file as base64 and inject via JavaScript
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let base64 = data.base64EncodedString()
        let fileName = fileURL.lastPathComponent
        let mimeType = fileName.hasSuffix(".pdf") ? "application/pdf" : "application/octet-stream"
        let fileSize = data.count

        let js = """
        (function(){
            var f = {
                name: '\(fileName.replacingOccurrences(of: "'", with: "\\'"))',
                type: '\(mimeType)',
                size: \(fileSize),
                dataUrl: 'data:\(mimeType);base64,\(base64)'
            };
            // Find the _editFiles array or create one
            if(typeof _editFiles !== 'undefined'){
                _editFiles.push(f);
                if(typeof renderFileList === 'function') renderFileList();
            }
            // Also trigger any reading file upload flow
            if(typeof currentBookId !== 'undefined' && currentBookId){
                var b = books.find(function(bk){return bk.id === currentBookId;});
                if(b){
                    if(!b.localFiles) b.localFiles = [];
                    b.localFiles.push(f);
                    saveBooks();
                    if(typeof openReadingView === 'function') openReadingView(currentBookId);
                }
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Page loaded
        }
    }
}

// MARK: - Main App
@main
struct ReadingListApp: App {
    @State private var droppedFileURL: URL? = nil

    var body: some Scene {
        WindowGroup {
            WebView(htmlName: "reading-list.html", droppedFileURL: $droppedFileURL)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    setupMenuBar()
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers)
                    return true
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加书籍") {
                    NotificationCenter.default.post(name: .addBook, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("文件") {
                Button("打开文件…") {
                    openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    private func setupMenuBar() {
        NotificationCenter.default.addObserver(
            forName: .addBook,
            object: nil,
            queue: .main
        ) { _ in
            // Trigger Add Book via JS in WebView
            evaluateInWebView("if(typeof openAddModal === 'function') openAddModal();")
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let ext = url.pathExtension.lowercased()
                guard ext == "pdf" || ext == "docx" else { return }
                DispatchQueue.main.async {
                    self.droppedFileURL = url
                }
            }
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, UTType("org.openxmlformats.wordprocessingml.document") ?? .data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                self.droppedFileURL = url
            }
        }
    }

    private func evaluateInWebView(_ js: String) {
        // Post to WebView's coordinator
        NotificationCenter.default.post(name: .evaluateJS, object: js)
    }
}

extension Notification.Name {
    static let addBook = Notification.Name("addBook")
    static let evaluateJS = Notification.Name("evaluateJS")
}
