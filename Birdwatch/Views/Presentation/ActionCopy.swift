import Foundation

/// What the daemon-restart confirmation says will happen. The restart is a
/// SIGTERM followed by launchd's own respawn (`MaintenanceActions`), so the
/// sheet describes exactly that — never "can't be undone" or "only local sync
/// state is affected", which describe a reset Birdwatch doesn't perform.
nonisolated enum RestartCopy {
    static func consequence(daemon name: String) -> String {
        let base = "Birdwatch asks \(name) to quit (SIGTERM) and macOS starts it again by itself, usually within seconds. Sync pauses while it restarts. No files are changed or deleted."
        guard name == "cloudd" else { return base }
        return base + " cloudd only starts when something needs CloudKit, so it may stay stopped until then."
    }
}

/// The conflict screen's wording. All Birdwatch knows is that iCloud holds
/// more than one unresolved version of the file — not when or how many
/// devices edited it — so it says only that, and the keep-all choice names
/// what `ConflictSource` really does (saves the others as conflicted copies).
nonisolated enum ConflictCopy {
    static func subtitle(location: String, versionCount: Int) -> String {
        "\(location) · \(Plural.count(versionCount, "version")) kept by iCloud"
    }

    static func explanation(versionCount: Int) -> String {
        let keep = versionCount > 2
            ? "keep all of them, and Birdwatch saves the others alongside as “(conflicted copy)” files."
            : "keep both, and Birdwatch saves the other alongside as a “(conflicted copy)” file."
        return "iCloud kept one version as the current file and saved the others for you to choose from. Choose the one to keep — or \(keep)"
    }

    static func keepAllButton(versionCount: Int) -> String {
        versionCount > 2 ? "Keep all versions" : "Keep both versions"
    }
}
