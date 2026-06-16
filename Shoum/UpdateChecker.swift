import Foundation

/// Notify-only update check — the single network call Shoum makes: one GitHub
/// API request for the latest commit on `main`, compared against the commit
/// stamped into the bundle at build time (Info.plist → ShoumGitCommit, set by
/// build.sh). Dev builds ("unknown" / "-dirty") and `check_for_updates: false`
/// skip it entirely. We notify; we never auto-apply.
final class UpdateChecker {
    static let repoSlug = "p-i-/shoum"
    static let repoURL = URL(string: "https://github.com/p-i-/shoum")!

    /// Short hash of the latest upstream commit, once a check has succeeded.
    private(set) var latestRemote: String?

    /// The commit this build was stamped with, or "unknown" if built outside git.
    var currentCommit: String {
        Bundle.main.object(forInfoDictionaryKey: "ShoumGitCommit") as? String ?? "unknown"
    }

    var isDevBuild: Bool {
        currentCommit == "unknown" || currentCommit.hasSuffix("-dirty")
    }

    /// Query upstream; report on the main queue whether a newer build exists.
    /// No-ops to `false` for dev builds or when disabled in config.
    func check(_ completion: @escaping (Bool) -> Void) {
        guard Config.shared.checkForUpdates, !isDevBuild else {
            completion(false)
            return
        }
        let url = URL(string: "https://api.github.com/repos/\(Self.repoSlug)/commits/main")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self = self else { return }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sha = obj["sha"] as? String, !sha.isEmpty else {
                Log.info("[UpdateChecker] check failed: \(error?.localizedDescription ?? "no/invalid response")")
                DispatchQueue.main.async { completion(false) }
                return
            }
            // currentCommit is the short hash; the API returns the full 40-char SHA.
            let available = !sha.hasPrefix(self.currentCommit)
            self.latestRemote = String(sha.prefix(7))
            Log.info("[UpdateChecker] current=\(self.currentCommit) latest=\(self.latestRemote ?? "?") updateAvailable=\(available)")
            DispatchQueue.main.async { completion(available) }
        }.resume()
    }
}
