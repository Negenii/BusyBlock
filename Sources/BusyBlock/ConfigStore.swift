import Foundation
import Combine
import BusyBlockCore

/// Owns config.json: loads it, saves edits, and reloads when the file changes on disk.
@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var config: Config
    let url: URL
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var reloadWork: DispatchWorkItem?
    private let log: (String) -> Void

    init(url: URL = Config.defaultURL, log: @escaping (String) -> Void = { print($0) }) {
        self.url = url
        self.log = log
        self.config = Config.loadOrCreate(at: url)
        watchDirectory()
    }

    func save(_ new: Config) {
        guard new != config else { return }
        config = new
        do { try new.save(to: url) } catch { log("config save failed: \(error)") }
    }

    private func reloadFromDisk() {
        guard let fresh = try? Config.load(from: url), fresh != config else { return }
        log("config reloaded from disk")
        config = fresh
    }

    /// Atomic saves replace the file, so watch the directory instead of the file.
    private func watchDirectory() {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirFD = open(dir.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.reloadWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reloadFromDisk() }
            self.reloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        src.setCancelHandler { [fd = dirFD] in close(fd) }
        src.resume()
        dirSource = src
    }
}
