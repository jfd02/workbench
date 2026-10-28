import CryptoKit
import Foundation

/// Build output that Xcode tools keep outside a worktree, deleted once the worktree is gone.
///
/// Xcode keeps a project's DerivedData in `~/Library/Developer/Xcode/DerivedData`
/// under a name made from the project's path, and MobileBuildMCP keeps its builds in
/// `~/Library/Developer/MobileBuildMCP/workspaces` under a name made from the
/// worktree's path, as it did in `XcodeBuildMCP/workspaces` before it was renamed.
/// Removing the worktree leaves them behind, and each can run to several gigabytes.
/// The names can be worked out from the path alone, so they're found even after
/// the worktree's folder is gone.
enum XcodeBuildFolders {
    private static let developerDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer")

    /// Delete the build folders of worktrees that have been removed, in the background.
    ///
    /// The Xcode projects are taken from `checkoutPath`, a checkout of the same
    /// repository that still exists, since each worktree has them at the same place.
    /// A path that still exists on disk is skipped.
    static func removeFolders(ofRemovedWorktrees worktreePaths: [String], checkoutPath: String?) {
        let removed = worktreePaths.filter { !FileManager.default.fileExists(atPath: $0) }
        guard !removed.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async {
            let projects = checkoutPath.map(trackedProjects(in:)) ?? []
            for worktreePath in removed {
                for folder in folders(ofWorktreeAt: worktreePath, projects: projects) {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }
    }

    private static func folders(ofWorktreeAt worktreePath: String, projects: [String]) -> [URL] {
        let derivedData = developerDirectory.appendingPathComponent("Xcode/DerivedData")
        let projectFolders = projects.map { project in
            derivedData.appendingPathComponent(
                derivedDataFolderName(forProjectAt: (worktreePath as NSString).appendingPathComponent(project)))
        }
        let workspaceFolders = ["MobileBuildMCP/workspaces", "XcodeBuildMCP/workspaces"].map { workspaces in
            developerDirectory.appendingPathComponent(workspaces)
                .appendingPathComponent(buildMCPFolderName(forWorktreeAt: worktreePath))
        }
        return projectFolders + workspaceFolders
    }

    /// The `.xcodeproj` and `.xcworkspace` paths git tracks, relative to the checkout.
    ///
    /// A project's own `project.xcworkspace` is left out: Xcode names the
    /// DerivedData folder after the project that contains it.
    private static func trackedProjects(in checkoutPath: String) -> [String] {
        guard let output = try? GitService.run(
            ["ls-files", "--", "*.xcodeproj/project.pbxproj", "*.xcworkspace/contents.xcworkspacedata"],
            in: checkoutPath
        ) else { return [] }

        let projects = output.split(separator: "\n").map { ($0 as NSString).deletingLastPathComponent }
        return Array(Set(projects.filter {
            !($0 as NSString).deletingLastPathComponent.hasSuffix(".xcodeproj")
        }))
    }

    /// The DerivedData folder Xcode uses for a project: its name, then the MD5 of
    /// its path spelled as 28 letters.
    static func derivedDataFolderName(forProjectAt projectPath: String) -> String {
        let digest = Array(Insecure.MD5.hash(data: Data(projectPath.utf8)))
        func letters(_ bytes: ArraySlice<UInt8>) -> String {
            var value = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            var result = [Character](repeating: "a", count: 14)
            for index in result.indices.reversed() {
                result[index] = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(value % 26)))
                value /= 26
            }
            return String(result)
        }
        let name = ((projectPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return "\(name)-\(letters(digest[0..<8]))\(letters(digest[8..<16]))"
    }

    /// The folder MobileBuildMCP uses for a worktree: its folder name made safe,
    /// then the first 12 hex digits of the SHA-256 of its path.
    static func buildMCPFolderName(forWorktreeAt worktreePath: String) -> String {
        let slug = String(
            (worktreePath as NSString).lastPathComponent
                .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
                .replacingOccurrences(of: "^[.-]+|[.-]+$", with: "", options: .regularExpression)
                .prefix(64))
        let hash = SHA256.hash(data: Data(worktreePath.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(slug.isEmpty ? "workspace" : slug)-\(hash.prefix(12))"
    }
}
