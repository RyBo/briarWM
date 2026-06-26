import Foundation

/// Watches the config file and invokes `onChange` (debounced) when it changes.
/// Re-arms itself across atomic saves (editors write a new inode then rename).
final class ConfigWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounceItem: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() { arm() }

    private func arm() {
        stop()
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // File may not exist yet; retry shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in self?.handleEvent() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        src.resume()
        source = src
    }

    private func handleEvent() {
        let flags = source?.data ?? []
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        // Atomic saves replace the file; re-arm on the new inode.
        if flags.contains(.delete) || flags.contains(.rename) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.arm() }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
