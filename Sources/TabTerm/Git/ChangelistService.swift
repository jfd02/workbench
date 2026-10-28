import Foundation

struct ChangedFile: Equatable {
    enum Area: String { case conflicted = "Conflicts", staged = "Staged", unstaged = "Unstaged", untracked = "Untracked" }
    var path: String
    var originalPath: String?
    var status: Character
    var area: Area

    var statusDescription: String {
        if area == .conflicted { return "Conflict" }
        switch status {
        case "M": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "T": return "Type changed"
        case "?": return "New file"
        default: return "Changed"
        }
    }

    var identity: String { area.rawValue + ":" + path }
    var title: String { originalPath.map { "\($0) → \(path)" } ?? path }
}

struct ChangelistSnapshot: Equatable {
    var files: [ChangedFile]
    var head: String?
}

enum ChangelistService {
    static func load(at directory: String) throws -> ChangelistSnapshot {
        let status = try ReviewCommand.git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: directory)
        // A newly initialized repository has no HEAD, but its files are still reviewable.
        let head = try? ReviewCommand.git(["rev-parse", "--verify", "HEAD"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ChangelistSnapshot(files: parse(status), head: head)
    }

    /// -z emits literal paths, destination first for renames, then the old path.
    static func parse(_ status: String) -> [ChangedFile] {
        var records = status.split(separator: "\0", omittingEmptySubsequences: false)[...]
        var files: [ChangedFile] = []
        let conflicts: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        while let record = records.popFirst() {
            guard record.count >= 4 else { continue }
            let code = String(record.prefix(2))
            let columns = Array(code)
            let path = String(record.dropFirst(3))
            let old = code.contains("R") || code.contains("C") ? records.popFirst().map(String.init) : nil
            if code == "??" {
                files.append(ChangedFile(path: path, status: "?", area: .untracked))
            } else if conflicts.contains(code) {
                files.append(ChangedFile(path: path, status: "U", area: .conflicted))
            } else if code != "!!" {
                if columns[0] != " " {
                    files.append(ChangedFile(path: path, originalPath: old, status: columns[0], area: .staged))
                }
                if columns[1] != " " {
                    files.append(ChangedFile(path: path, originalPath: old, status: columns[1], area: .unstaged))
                }
            }
        }
        let order: [ChangedFile.Area] = [.conflicted, .staged, .unstaged, .untracked]
        return files.sorted {
            if $0.area != $1.area { return order.firstIndex(of: $0.area)! < order.firstIndex(of: $1.area)! }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    static func preview(_ file: ChangedFile, at directory: String) throws -> String {
        if file.area == .untracked {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(file.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                return "Symbolic link → " + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return "No text preview for this file type." }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 256 * 1024 + 1) ?? Data()
            guard !data.contains(0), let text = String(data: data.prefix(256 * 1024), encoding: .utf8) else {
                return "Binary or non-UTF-8 file — no text preview."
            }
            return text + (data.count > 256 * 1024 ? "\n\n[Preview truncated at 256 KiB]" : "")
        }
        var arguments = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames"]
        if file.area == .staged { arguments.append("--cached") }
        arguments.append("--")
        if let old = file.originalPath { arguments.append(old) }
        arguments.append(file.path)
        let diff = try ReviewCommand.git(arguments, in: directory, limit: 512 * 1024)
        return diff.isEmpty ? "No textual diff. The file may have changed since the last refresh." : diff
    }
}
