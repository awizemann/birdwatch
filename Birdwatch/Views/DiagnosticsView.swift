import SwiftUI
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.birdwatch", category: "diagnostics")

/// A maintenance/daemon action awaiting confirmation, carrying the real work.
private struct ConfirmAction: Identifiable {
    let title: String
    let command: String
    /// The consequence sentence. Defaulted to the sync-state wording; a Trash
    /// action overrides it, because "this can't be undone" is simply false for
    /// something recoverable from the Trash and would scare a user out of the
    /// one safe cleanup the app offers.
    var detail = "This can't be undone. Your files stay safe in iCloud — only local sync state is affected."
    /// Focus-restoration identity. Distinct from `title` because two retry rows
    /// can legitimately share the same human title ("Move .bin file to Trash")
    /// while needing different buttons to regain focus.
    var identity: String? = nil
    let perform: () -> Void
    var id: String { identity ?? title }
}

/// `.bordered` vs `.borderedProminent` chosen at runtime. The two styles are
/// different types, so the branch has to live in a modifier rather than a
/// ternary — and AnyView on a row that repeats per retry item is not worth it.
private struct ProminentWhen: ViewModifier {
    let prominent: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

struct DiagnosticsView: View {
    @Environment(SyncStore.self) private var store
    @State private var confirmAction: ConfirmAction?
    /// Transient result line for the maintenance card; auto-clears after 10s.
    @State private var actionStatus: ActionStatus?
    @State private var statusClearTask: Task<Void, Never>?
    /// The same, for the retry card. Deliberately a SECOND line rather than a
    /// shared one: the maintenance card sits three sections below the retry
    /// rows, and reporting a row's outcome down there is why "Move to Trash"
    /// read as doing nothing at all.
    @State private var retryStatus: ActionStatus?
    @State private var retryStatusClearTask: Task<Void, Never>?
    @State private var copiedDiagnoseCommand = false
    @State private var copyResetTask: Task<Void, Never>?
    /// One actor for the whole app, created by `BirdwatchApp` and injected —
    /// NOT a stored `let`, which minted a fresh actor every time SwiftUI
    /// re-created this struct and left each in-flight restart talking to an
    /// instance nobody else could see.
    @Environment(\.maintenanceActions) private var maintenance
    @AppStorage("bw_setup_complete") private var setupComplete = true

    private struct ActionStatus: Equatable {
        let text: String
        /// Three states, not two: an action can land without us being able to
        /// confirm the outcome (a signalled daemon that launchd has not
        /// relaunched yet), and painting that green would be a claim we did
        /// not verify.
        enum Tone { case success, caution, failure }
        var tone: Tone = .success
        /// The retry row this outcome belongs to, when it belongs to one. The
        /// retry card is ten rows tall; reporting a row's outcome at the bottom
        /// of it (below the rows AND the footnote) is why "Move to Trash" read
        /// as saying nothing at all — the answer was eight rows away from the
        /// button. A failure renders IN its row; a success has no row left to
        /// render in, so it falls back to the card.
        var rowID: String? = nil
        var color: Color {
            switch tone {
            case .success: Palette.success
            case .caution: Palette.warning
            case .failure: Palette.error
            }
        }
    }
    /// Identity (ConfirmAction.title) of the row button that opened the
    /// confirm sheet — focus returns to that button when the sheet dismisses.
    @State private var pendingActionID: String?
    @FocusState private var focusedActionID: String?

    var body: some View {
        ContentColumn {
            ViewHeader(title: MonitorView.diagnostics.title, subtitle: MonitorView.diagnostics.subtitle)

            SectionLabel(text: "Sync daemons")
            daemonsCard

            // Full width, stacked: both cards carry long values (bird's
            // "client 1,234,567 items (bird truncated its dump)" and resolved
            // file paths) that a two-column split truncated mid-word.
            SectionLabel(text: "Sync engine")
            engineCard

            SectionLabel(text: "Retry queue")
            retryCard

            SectionLabel(text: "Maintenance")
            maintenanceCard

            SectionLabel(text: "System Access")
            systemAccessCard

            SourceFootnote(text: "Daemon stats via proc_pid_rusage · engine state via brctl status · retry queue, budgets and item counts via brctl dump -i")
        }
        // The three transient-status timers are the only tasks this screen
        // owns, and they outlive it: each sleeps 10s before clearing a line
        // that is already gone once the sidebar switches away. Cancel them
        // with the view and drop the lines, so a revisit starts clean.
        //
        // In-flight maintenance operations are deliberately NOT cancelled
        // here. The SIGTERM has already been sent by then; cancelling would
        // only abandon the bounded respawn poll that decides whether the
        // restart is reported as confirmed or unconfirmed — throwing away the
        // observation, not the effect.
        .onDisappear {
            statusClearTask?.cancel()
            retryStatusClearTask?.cancel()
            copyResetTask?.cancel()
            actionStatus = nil
            retryStatus = nil
            copiedDiagnoseCommand = false
        }
        .sheet(item: $confirmAction, onDismiss: {
            if let id = pendingActionID {
                focusedActionID = id
                pendingActionID = nil
            }
        }) { action in
            ConfirmDialog(action: action) {
                // NOT .public: a retry-row Trash action puts the file name in
                // `title` and its full path in `command`, so this one line
                // would print both to a log anyone can read (C7).
                logger.info("Confirmed maintenance action: \(action.title, privacy: .private) — \(action.command, privacy: .private)")
                action.perform()
                confirmAction = nil
            } onCancel: {
                confirmAction = nil
            }
        }
    }

    // MARK: - Running actions

    /// Runs a maintenance operation on the actor, logs the outcome, and shows
    /// a transient success/failure line in the maintenance card.
    ///
    /// Every operation routed here today is a daemon restart, which is why the
    /// usage event is `restart_daemon` with the daemon's name — a closed set
    /// (bird / cloudd / fileproviderd), not user data.
    private func run(_ title: String, daemon: String, operation: @escaping () async throws -> String) {
        Task {
            do {
                let result = try await operation()
                // `title` stays .public deliberately: every caller passes a
                // daemon name or a `maintenanceItems` title — a closed, static
                // set with no user data in it. The results do not (C7).
                logger.info("\(title, privacy: .public) succeeded: \(result, privacy: .private)")
                let tone: ActionStatus.Tone =
                    result == MaintenanceActions.respawnNotObserved ? .caution : .success
                show(ActionStatus(text: "\(title): \(result)", tone: tone))
                store.record(.maintenanceRun(.restart_daemon, daemon: daemon, outcome: .ok, errorKind: nil))
            } catch {
                let reason = Self.shortReason(for: error)
                logger.error("\(title, privacy: .public) failed: \(reason, privacy: .private)")
                show(ActionStatus(text: "Failed: \(reason)", tone: .failure))
                store.record(.maintenanceRun(.restart_daemon, daemon: daemon, outcome: .failed, errorKind: Self.errorKind(for: error)))
            }
        }
    }

    /// The error's *kind* for analytics — a `MaintenanceError` case name or
    /// "other". An explicit switch, never reflection or the message: every
    /// payload is a path or daemon name and must not travel.
    static func errorKind(for error: Error) -> String {
        guard let m = error as? MaintenanceError else { return "other" }
        switch m {
        case .notSupported: return "notSupported"
        case .unknownDaemon: return "unknownDaemon"
        case .daemonNotRunning: return "daemonNotRunning"
        case .pathNotAllowed: return "pathNotAllowed"
        case .requiresTerminal: return "requiresTerminal"
        }
    }

    private func show(_ status: ActionStatus) {
        actionStatus = status
        AccessibilityNotification.Announcement(status.text).post()
        statusClearTask?.cancel()
        statusClearTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            actionStatus = nil
        }
    }

    private func showRetryStatus(_ status: ActionStatus) {
        withAnimation { retryStatus = status }
        AccessibilityNotification.Announcement(status.text).post()
        retryStatusClearTask?.cancel()
        retryStatusClearTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            withAnimation { retryStatus = nil }
        }
    }

    private static func shortReason(for error: Error) -> String {
        switch error {
        case RunnerError.timeout: "timed out"
        case RunnerError.launchFailed(let detail): "could not launch (\(detail))"
        case RunnerError.nonZeroExit(let code, let stderr):
            "exit \(code)\(stderr.isEmpty ? "" : " — \(stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))")"
        case MaintenanceError.notSupported(let why): why
        case MaintenanceError.unknownDaemon(let name): "no launchd service for \(name)"
        default: String(describing: error)
        }
    }

    // MARK: - Sync daemons

    private var daemonsCard: some View {
        Card {
            VStack(spacing: 0) {
                ForEach(Array(store.daemons.enumerated()), id: \.element.id) { index, daemon in
                    if index > 0 { Divider().overlay(Surface.cardLine) }
                    daemonRow(daemon)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    /// Visible CPU health word paired with the tint color (§12 — never color alone).
    private func cpuHealthWord(_ percent: Double) -> String {
        if percent < 15 { "Healthy" } else if percent < 30 { "Elevated" } else { "High load" }
    }

    private func daemonRow(_ daemon: DaemonStat) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                StatusDot(color: cpuTint(daemon.cpuPercent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(daemon.name)
                        .scaledFont(size: 13, weight: .semibold, design: .monospaced)
                        .foregroundStyle(Surface.fg)
                    Text(daemon.role)
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg2)
                }
                .frame(minWidth: 170, alignment: .leading)

                MiniProgressBar(progress: daemon.cpuPercent / 100, tint: cpuTint(daemon.cpuPercent), label: "\(daemon.name) CPU")
                    .frame(maxWidth: 140)

                Text("\(Int(daemon.cpuPercent))% CPU")
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(Surface.fg)
                    .monospacedDigit()
                    .frame(minWidth: 70, alignment: .trailing)

                Text(cpuHealthWord(daemon.cpuPercent))
                    .scaledFont(size: 11.5, weight: .semibold)
                    .foregroundStyle(cpuTint(daemon.cpuPercent))

                Text("\(Int(daemon.memoryMB)) MB")
                    .scaledFont(size: 12)
                    .foregroundStyle(Surface.fg2)
                    .monospacedDigit()
                    .frame(minWidth: 56, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            Button("Restart") {
                let name = daemon.name
                pendingActionID = "Restart \(name)"
                confirmAction = ConfirmAction(
                    title: "Restart \(name)",
                    command: MaintenanceActions.restartCommand(name: name),
                    perform: { run("Restart \(name)", daemon: name) { try await maintenance.restartDaemon(name: name) } }
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focused($focusedActionID, equals: "Restart \(daemon.name)")
            .accessibilityLabel("Restart \(daemon.name)")
        }
    }

    // MARK: - Sync engine

    private var engineCard: some View {
        Card {
            VStack(spacing: 0) {
                if let engine = store.engine {
                    engineRow(label: "Server state", value: engine.serverState)
                    Divider().overlay(Surface.cardLine)
                    engineRow(label: "Client state", value: engine.clientState)
                    Divider().overlay(Surface.cardLine)
                    engineRow(label: "Last sync token", value: engine.lastSyncToken, monospace: true)
                    Divider().overlay(Surface.cardLine)
                    engineRow(label: "Push budget", value: engine.pushBudget,
                              valueColor: engine.pushThrottled ? Palette.warning : Surface.fg)
                    Divider().overlay(Surface.cardLine)
                    engineRow(label: "Metadata index", value: engine.metadataIndex,
                              valueColor: engine.metadataHealthy ? Palette.success : Palette.warning)
                    if let progress = engine.globalProgressLine {
                        Divider().overlay(Surface.cardLine)
                        engineRow(label: "Upload batch", value: progress)
                    }
                }
            }
        }
    }

    private func engineRow(label: String, value: String, monospace: Bool = false, valueColor: Color = Surface.fg) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .scaledFont(size: 12.5)
                .foregroundStyle(Surface.fg2)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 16)
            // Wrap, never truncate: "(bird truncated its dump)" is the tail of
            // the longest value and is exactly the part that matters.
            Text(value)
                .scaledFont(size: 12.5, weight: .semibold, design: monospace ? .monospaced : .default)
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Retry queue

    private var retryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                if store.retryQueue.isEmpty {
                    Text("Nothing is queued for retry.")
                        .scaledFont(size: 12.5)
                        .foregroundStyle(Surface.fg2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(store.retryQueue.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().overlay(Surface.cardLine) }
                        retryRow(item)
                            .padding(.vertical, 8)
                    }
                    // macOS length-redacts every file name in the dump, so the
                    // extension is all that survives. Say so rather than
                    // letting ".bin file" read as a bug.
                    Text(retryFootnote)
                        .scaledFont(size: 11)
                        .foregroundStyle(Surface.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                // Card-level line for outcomes with no row left to sit in (a
                // success removes its row). It also renders when the queue is
                // empty, because trashing the LAST row is exactly when the user
                // most needs to be told it worked.
                if let status = retryStatus, !store.retryQueue.contains(where: { $0.id == status.rowID }) {
                    Divider().overlay(Surface.cardLine).padding(.top, 8)
                    statusLine(status)
                        .padding(.top, 8)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: store.retryQueue)
        }
    }

    /// StatusDot + text — colour is never the only signal (§12), the words carry
    /// the outcome on their own.
    private func statusLine(_ status: ActionStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(color: status.color)
            Text(status.text)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(status.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var retryFootnote: String {
        let shown = store.retryQueue.count
        let total = store.retryQueueTotal
        let scope = total > shown ? "Showing \(shown) of \(total) scheduled items. " : ""
        let base = "macOS redacts file names in bird's diagnostic output — only the file type survives."
        let resolvedAny = store.retryQueue.contains { $0.matchConfidence != .none }
        let located = resolvedAny
            ? " Paths come from Birdwatch reading this Mac's own iCloud Drive folder and finding the file that fits the redacted pattern — not from bird."
            : ""
        return scope + base + located
    }

    private func retryRow(_ item: RetryQueueItem) -> some View {
        let atMax = item.attempt >= item.maxAttempts
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(Surface.fg)
                    .lineLimit(1)
                if let ago = item.lastAttemptAgo {
                    Text("· last try \(Format.duration(ago)) ago")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Surface.fg3)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                Text("attempt \(item.attempt) of \(item.maxAttempts)")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(atMax ? Palette.error : Surface.fg2)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                pathLine(item)
                Spacer(minLength: 8)
                rowActions(item)
            }
            MiniProgressBar(
                progress: Double(item.attempt) / Double(item.maxAttempts),
                tint: atMax ? Palette.error : Palette.warning,
                label: "Retry attempts"
            )
            if let status = retryStatus, status.rowID == item.id {
                statusLine(status).transition(.opacity)
            }
        }
    }

    /// The honest location line. bird redacts the name; this is what OUR OWN
    /// filesystem says fits the pattern it printed — a fact about this disk, so
    /// it is stated as one. No fit, no line beyond the redaction notice.
    @ViewBuilder
    private func pathLine(_ item: RetryQueueItem) -> some View {
        switch item.matchConfidence {
        case .exact:
            if let path = item.path {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.isDirectory ? "folder" : "doc")
                            .scaledFont(size: 10.5)
                            .foregroundStyle(Surface.fg3)
                            .accessibilityHidden(true)
                        Text(path)
                            .scaledFont(size: 11.5, design: .monospaced)
                            .foregroundStyle(Surface.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let measure = Self.sizeLine(item) {
                        Text(measure)
                            .scaledFont(size: 11)
                            .foregroundStyle(Surface.fg3)
                            .monospacedDigit()
                    }
                    // No button on this row, so the row has to say why. Without
                    // it, a folder that is plainly empty and plainly there just
                    // sits with a Reveal button and no explanation.
                    if let why = Self.noTrashReason(item) {
                        Text(why)
                            .scaledFont(size: 11)
                            .foregroundStyle(Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contextMenu {
                    if let absolute = item.absolutePath {
                        Button("Reveal in Finder") { reveal(absolute) }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(absolute, forType: .string)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Located at \(path)\(Self.sizeLine(item).map { ", \($0)" } ?? "")")
            }
        case .ambiguous(let count):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("One of \(count) files matching the redacted pattern")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Surface.fg3)
                if let parent = item.path {
                    Text("in \(parent)")
                        .scaledFont(size: 11.5, design: .monospaced)
                        .foregroundStyle(Surface.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
        case .none:
            Text("Location redacted by macOS")
                .scaledFont(size: 11.5)
                .foregroundStyle(Surface.fg3)
        }
    }

    /// "Empty folder" / "12 items · 1.2 GB" / "1.2 GB", plus — when nothing can
    /// be done about it — the reason there is no button. nil when we have not
    /// measured the item yet (or it vanished): no line beats a fake zero.
    static func sizeLine(_ item: RetryQueueItem) -> String? {
        guard let bytes = item.sizeBytes else {
            // Resolved to a path but the size pass could not stat it: iCloud
            // lists the folder, yet nothing exists on this disk to move or
            // reveal into. Say so instead of offering a Trash button that
            // fails every time (measured live: NSCocoaErrorDomain 4).
            if item.matchConfidence == .exact, item.absolutePath != nil {
                return "Listed by iCloud, but no folder exists on this Mac"
            }
            return nil
        }
        let size = Format.size(bytes) + (item.sizeIsPartial ? "+" : "")
        guard let count = item.itemCount else { return size }
        if count == 0 { return "Empty folder" }
        return "\(count) item\(count == 1 ? "" : "s") · \(size)"
    }

    /// Why this row has no "Move to Trash" button, in the user's terms — or nil
    /// when it has one. Static so the wording is unit-testable without a view.
    static func noTrashReason(_ item: RetryQueueItem) -> String? {
        guard item.matchConfidence == .exact, let absolute = item.absolutePath,
              item.sizeBytes != nil else { return nil }
        if FileTrasher.isUbiquityDocumentRoot(path: absolute) {
            return "iCloud owns this folder, so macOS won't let anything move it — not Birdwatch, not Finder. Removing the app's data from iCloud is done in System Settings › Apple Account › iCloud."
        }
        if !FileTrasher.isAllowed(path: absolute) {
            return "It is outside the folders Birdwatch is allowed to touch."
        }
        return nil
    }

    /// The right-hand button group. `Reveal in Finder` leads except on an empty
    /// folder, where throwing it away IS the useful action — but it still goes
    /// through the confirm sheet, because a delete is never a single click.
    @ViewBuilder
    private func rowActions(_ item: RetryQueueItem) -> some View {
        if item.matchConfidence == .exact, let absolute = item.absolutePath {
            let isEmptyFolder = item.itemCount == 0
            // Dead-button rule, twice over:
            // 1. A resolved path the size pass could not stat is a phantom —
            //    iCloud lists it, nothing is on this disk to move.
            // 2. An app's ubiquity document root REFUSES to be trashed. That is
            //    not a guess: the button failed live with NSCocoaErrorDomain
            //    3328, "the volume … doesn't have one" (see
            //    FileTrasher.isUbiquityDocumentRoot). Every row bird offers on
            //    this Mac is one, which is why the button appeared to do
            //    nothing at all.
            let existsOnDisk = item.sizeBytes != nil
            let isManagedRoot = FileTrasher.isUbiquityDocumentRoot(path: absolute)
            let canTrash = existsOnDisk && !isManagedRoot && FileTrasher.isAllowed(path: absolute)
            HStack(spacing: 6) {
                Button("Reveal in Finder") { reveal(absolute) }
                    .modifier(ProminentWhen(prominent: !isEmptyFolder))
                    .accessibilityLabel("Reveal \(item.name) in Finder")
                if canTrash {
                    Button(isEmptyFolder ? "Move to Trash" : "Move to Trash…") {
                        // bird's item id names one of the user's files (C7).
                        logger.info("Move to Trash tapped for retry row \(item.id, privacy: .private)")
                        confirmTrash(item, absolutePath: absolute)
                    }
                    .modifier(ProminentWhen(prominent: isEmptyFolder))
                    .tint(isEmptyFolder ? Palette.error : nil)
                    .focused($focusedActionID, equals: Self.trashActionID(item))
                    .accessibilityLabel("Move \(item.name) to Trash")
                }
            }
            .controlSize(.small)
            .scaledFont(size: 11)
            .fixedSize()
        }
    }

    static func trashActionID(_ item: RetryQueueItem) -> String { "Move to Trash — \(item.id)" }

    private func confirmTrash(_ item: RetryQueueItem, absolutePath: String) {
        let id = Self.trashActionID(item)
        pendingActionID = id
        let contents: String = if item.itemCount == 0 {
            "This folder is empty."
        } else if let line = Self.sizeLine(item) {
            "Contains \(line)."
        } else {
            "Its contents have not been measured."
        }
        confirmAction = ConfirmAction(
            title: "Move \(item.name) to Trash",
            command: item.path ?? absolutePath,
            detail: "\(contents) It moves to the Trash and stays recoverable there until you empty it.",
            identity: id,
            perform: {
                // The whole operation is the store's — trash, then forget, then
                // refresh, and the row only goes when the file actually did.
                logger.info("Trash confirmed for retry row \(id, privacy: .private); calling the store")
                Task {
                    switch await store.trashRetryQueueItem(item) {
                    case .moved(let name, let destination):
                        logger.info("Store reported MOVED for \(id, privacy: .private)")
                        // Where it landed is part of the outcome: iCloud Drive
                        // keeps its own trash, so "check the Trash" alone sends
                        // people to the wrong folder.
                        showRetryStatus(ActionStatus(
                            text: destination.map {
                                "Moved “\(name)” to the Trash (\($0)) — recoverable in Finder"
                            } ?? "Moved “\(name)” to the Trash — recoverable in Finder",
                            tone: .success,
                            rowID: item.id
                        ))
                    case .failed(let name, let reason):
                        // The reason quotes the file name back at us (C7).
                        logger.error("Move to Trash failed: \(reason, privacy: .private)")
                        showRetryStatus(ActionStatus(
                            text: "Couldn’t move “\(name)” to the Trash: \(reason)",
                            tone: .failure,
                            rowID: item.id
                        ))
                    }
                }
            }
        )
    }

    private func reveal(_ absolutePath: String) {
        logger.info("Reveal in Finder requested for a retry-queue item")
        store.record(.retryItemRevealed)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
    }

    // MARK: - Maintenance

    // Re-index metadata and Reset CloudDocs are deliberately absent: neither
    // has a safe public command (MaintenanceActions throws notSupported), and
    // dead buttons don't ship. The footnote below says so.
    private struct MaintenanceItem: Identifiable {
        let title: String
        let command: String
        let actionLabel: String
        var needsConfirm = false
        /// Which daemon the row acts on (analytics prop; closed set).
        let daemon: String
        let operation: @MainActor (MaintenanceActions) async throws -> String
        var id: String { title }
    }

    private static let maintenanceItems: [MaintenanceItem] = [
        MaintenanceItem(
            title: "Restart bird",
            command: MaintenanceActions.restartCommand(name: "bird"),
            actionLabel: "Restart",
            needsConfirm: true,
            daemon: "bird",
            operation: { try await $0.restartDaemon(name: "bird") }
        ),
    ]

    private var maintenanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(Self.maintenanceItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().overlay(Surface.cardLine) }
                        maintenanceRow(item)
                            .padding(.vertical, 9)
                    }
                    Divider().overlay(Surface.cardLine)
                    diagnoseRow
                        .padding(.vertical, 9)
                    if let status = actionStatus {
                        Divider().overlay(Surface.cardLine)
                        statusLine(status)
                            .padding(.vertical, 9)
                    }
                }
            }
            SourceFootnote(text: "Restart signals the daemon and waits for launchd to bring it back — `launchctl kickstart` and `launchctl stop` are both refused (exit 150) while System Integrity Protection is on, so they are not used. cloudd is launched on demand, so it can legitimately stay down until something asks it for a CloudKit operation. Destructive CloudDocs resets and metadata re-indexing are deliberately not offered — macOS provides no safe public command for either.")
        }
    }

    /// `brctl diagnose` has no Run button and never will: it invokes `sudo`
    /// internally, and a GUI process has no terminal to prompt on — it failed
    /// every single time with "sudo: a terminal is required to read the
    /// password". Dead buttons don't ship, so the row hands the user the
    /// command instead of pretending to run it.
    private var diagnoseRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Run brctl diagnose in Terminal")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Surface.fg)
                Text(MaintenanceActions.diagnoseCommand)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(Surface.fg2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Surface.hover, in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
                Text("brctl diagnose needs administrator rights (it uses sudo), so it must run in Terminal. Paste the command; the archive path prints when it finishes.")
                    .scaledFont(size: 11)
                    .foregroundStyle(Surface.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Button(copiedDiagnoseCommand ? "Copied" : "Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MaintenanceActions.diagnoseCommand, forType: .string)
                    logger.info("Copied the brctl diagnose command to the pasteboard")
                    store.record(.maintenanceRun(.diagnose_copy_command, daemon: nil, outcome: .ok, errorKind: nil))
                    withAnimation { copiedDiagnoseCommand = true }
                    copyResetTask?.cancel()
                    copyResetTask = Task {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        withAnimation { copiedDiagnoseCommand = false }
                    }
                }
                .accessibilityLabel("Copy the brctl diagnose command")
                Button("Open Terminal") {
                    logger.info("Open Terminal requested for brctl diagnose")
                    store.record(.maintenanceRun(.diagnose_open_terminal, daemon: nil, outcome: .ok, errorKind: nil))
                    if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                        NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                .accessibilityLabel("Open Terminal")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private func maintenanceRow(_ item: MaintenanceItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Surface.fg)
                Text(item.command)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(Surface.fg3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button(item.actionLabel) {
                if item.needsConfirm {
                    pendingActionID = item.title
                    confirmAction = ConfirmAction(
                        title: item.title,
                        command: item.command,
                        perform: { run(item.title, daemon: item.daemon) { try await item.operation(maintenance) } }
                    )
                } else {
                    run(item.title, daemon: item.daemon) { try await item.operation(maintenance) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focused($focusedActionID, equals: item.title)
        }
    }

    // MARK: - System Access

    private var systemAccessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.permissions.enumerated()), id: \.element.id) { index, permission in
                    if index > 0 { Divider().overlay(Surface.cardLine) }
                    HStack(spacing: 10) {
                        StatusDot(color: permission.granted ? Palette.success : Palette.warning)
                        Text(permission.name)
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(Surface.fg)
                        Spacer()
                        Text(permission.granted ? "Granted" : "Not granted")
                            .scaledFont(size: 12.5, weight: .semibold)
                            .foregroundStyle(permission.granted ? Palette.success : Palette.warning)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle")
                        .scaledFont(size: 12)
                        .foregroundStyle(Palette.accent)
                    Text("Birdwatch runs outside the App Sandbox so it can read sync state from bird, cloudd and fileproviderd.")
                        .scaledFont(size: 12)
                        .foregroundStyle(Surface.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 10)

                Button("Re-run setup…") {
                    logger.info("Re-run setup requested")
                    setupComplete = false
                }
                .buttonStyle(.link)
                .scaledFont(size: 12.5, weight: .semibold)
                .padding(.top, 10)

                Divider().overlay(Surface.cardLine).padding(.vertical, 10)

                // The opt-out a person can find (swift-stats consumer
                // checklist §4). Copy says exactly what is and isn't sent.
                Toggle(isOn: usageSharingBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Share anonymous usage")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(Surface.fg)
                        Text("Which screens and actions get used, plus app version and macOS version, under a random install ID. Never file names, paths, app names or account details.")
                            .scaledFont(size: 11.5)
                            .foregroundStyle(Surface.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .task { await store.loadUsagePreference() }
            }
        }
    }

    private var usageSharingBinding: Binding<Bool> {
        Binding(get: { store.usageSharingEnabled }, set: { store.setUsageSharing($0) })
    }
}

// MARK: - Confirm dialog (360pt card per handoff)

private struct ConfirmDialog: View {
    let action: ConfirmAction
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Circle()
                .fill(Palette.error.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay {
                    Text("!")
                        .scaledFont(size: 22, weight: .bold)
                        .foregroundStyle(Palette.error)
                }
                .accessibilityHidden(true)

            Text("\(action.title)?")
                .scaledFont(size: 15, weight: .bold)
                .foregroundStyle(Surface.fg)
                .accessibilityAddTraits(.isHeader)

            Text(action.command)
                .scaledFont(size: 11.5, design: .monospaced)
                .foregroundStyle(Surface.fg2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Surface.hover, in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)

            Text(action.detail)
                .scaledFont(size: 12)
                .foregroundStyle(Surface.fg2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                // Deliberately no .defaultAction on the destructive confirm:
                // Return must not confirm a destructive action. Cancel gets
                // initial keyboard/VoiceOver focus instead.
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                Button(action.title, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.error)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(minWidth: 360)
        .background(Surface.card)
        .onAppear { cancelFocused = true }
    }
}
