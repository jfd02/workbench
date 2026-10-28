import Foundation

/// Notices worktrees being added or removed outside Workbench.
///
/// git keeps one folder per linked worktree in `<common dir>/worktrees`, so
/// that folder changes whenever one comes or goes. Until a repository has any
/// linked worktrees the folder doesn't exist, so the common dir itself is
/// watched instead, to see it appear.
final class WorktreeWatcher {
    /// Called on the main queue with the repository whose worktrees may have changed.
    var onChange: ((Repository) -> Void)?

    private struct Watch {
        var repository: Repository
        var commonDirectory: String
        var watchedPath: String
        var source: DispatchSourceFileSystemObject
    }

    private var watches: [Int64: Watch] = [:]
    private var pending: Set<Int64> = []

    deinit {
        for watch in watches.values { watch.source.cancel() }
    }

    /// Watch exactly these repositories, keeping watches that are already running.
    func watch(_ repositories: [Repository]) {
        let wanted = Dictionary(uniqueKeysWithValues: repositories.compactMap { repository in
            repository.id.map { ($0, repository) }
        })

        for (id, watch) in watches where wanted[id] == nil {
            watch.source.cancel()
            watches.removeValue(forKey: id)
        }
        for (id, repository) in wanted {
            if var existing = watches[id] {
                existing.repository = repository
                watches[id] = existing
            } else if let common = GitService.commonDirectory(for: repository.path) {
                start(repository, id: id, commonDirectory: common)
            }
        }
    }

    private func start(_ repository: Repository, id: Int64, commonDirectory: String) {
        let worktreesPath = (commonDirectory as NSString).appendingPathComponent("worktrees")
        let path = FileManager.default.fileExists(atPath: worktreesPath) ? worktreesPath : commonDirectory

        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.changed(id) }
        source.setCancelHandler { close(descriptor) }
        source.resume()

        watches[id] = Watch(
            repository: repository,
            commonDirectory: commonDirectory,
            watchedPath: path,
            source: source
        )
    }

    private func changed(_ id: Int64) {
        // git touches these folders several times per command; settle first.
        guard pending.insert(id).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.pending.remove(id)
            guard let watch = self.watches[id] else { return }

            // The worktrees folder may have appeared or been removed with the
            // last linked worktree; move the watch to whichever applies now.
            let worktreesPath = (watch.commonDirectory as NSString).appendingPathComponent("worktrees")
            let wantedPath = FileManager.default.fileExists(atPath: worktreesPath)
                ? worktreesPath : watch.commonDirectory
            if wantedPath != watch.watchedPath {
                watch.source.cancel()
                self.watches.removeValue(forKey: id)
                self.start(watch.repository, id: id, commonDirectory: watch.commonDirectory)
            }

            self.onChange?(watch.repository)
        }
    }
}
