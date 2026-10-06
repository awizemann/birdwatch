import SwiftUI

/// iCloud Drive — folders table + files in transfer (handoff §3).
struct DriveView: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        ContentColumn {
            ViewHeader(title: MonitorView.drive.title, subtitle: MonitorView.drive.subtitle)

            // Before the first folder scan lands the table would just be
            // empty; once a rescan overruns, the rows are an older result.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let notice = ScanFreshnessNotice.text(store.folderScan, subject: "iCloud Drive folders", now: context.date) {
                    SourceFootnote(text: notice)
                }
            }

            // Folders table card
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack {
                        SectionLabel(text: "Folder")
                        Spacer()
                        SectionLabel(text: "Items")
                            .frame(minWidth: 110, alignment: .leading)
                        SectionLabel(text: "Status")
                            .frame(minWidth: 150, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    let engineUnknown = store.app(withID: "icloud-drive")?.status == .unknown
                    let ddUnwatched = store.unwatchedApps.contains { $0.id == "desktop-documents" }
                    ForEach(store.driveFolders) { folder in
                        Divider().overlay(Surface.cardLine)
                        FolderRow(folder: folder, display: DriveFolderDisplay.display(
                            folder,
                            progressIsIndeterminate: store.progressIsIndeterminate(folderName: folder.name),
                            engineStateUnknown: engineUnknown, paused: store.isGloballyPaused,
                            desktopDocumentsUnwatched: ddUnwatched
                        ))
                    }
                }
            }

            // Files in transfer card
            SectionLabel(text: "Files in transfer")
                .padding(.top, 4)
            let note = TransferWatchNotes.qualifier(paused: store.isGloballyPaused, unwatched: store.unwatchedApps)
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    // While paused the note below is the whole answer.
                    if store.transfers.isEmpty && !store.isGloballyPaused {
                        Text("No files in transfer right now.")
                            .scaledFont(size: 12.5)
                            .foregroundStyle(Surface.fg2)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    ForEach(Array(store.transfers.enumerated()), id: \.element.id) { index, transfer in
                        if index > 0 { Divider().overlay(Surface.cardLine) }
                        TransferRow(transfer: transfer)
                    }
                    if let note {
                        Divider().overlay(Surface.cardLine)
                        Text(note)
                            .scaledFont(size: 12)
                            .foregroundStyle(Surface.fg2)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SourceFootnote(text: "Read from bird (CloudDocs) via brctl dump -i (engine state) and brctl status (Desktop & Documents setting); file transfers via FSEvents and per-file ubiquity flags.")
        }
    }
}

// MARK: - Rows

private struct FolderRow: View {
    let folder: DriveFolder
    let display: SyncStatusDisplay

    var body: some View {
        HStack(spacing: 10) {
            ColorTile(colorHex: "30b0c7", symbolName: "folder.fill", size: 26)

            Text(folder.name)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(Surface.fg)

            Spacer()

            Text(folder.itemCountText)
                .scaledFont(size: 12.5)
                .foregroundStyle(Surface.fg2)
                .monospacedDigit()
                .frame(minWidth: 110, alignment: .leading)

            statusColumn
                .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), \(folder.itemCountText), \(display.label)")
    }

    @ViewBuilder
    private var statusColumn: some View {
        switch display.bar {
        case .determinate(let progress):
            HStack(spacing: 8) {
                MiniProgressBar(progress: progress, label: "\(folder.name) sync progress")
                    .frame(width: 90)
                Text("\(Int((progress * 100).rounded()))%")
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(Palette.accent)
                    .monospacedDigit()
            }
        case .indeterminate:
            // The channel says "in progress" and nothing more.
            HStack(spacing: 8) {
                MiniProgressBar(progress: 0, label: "\(folder.name) sync progress", indeterminate: true)
                    .frame(width: 90)
                Text(display.label)
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(Palette.accent)
            }
        case nil:
            Text(display.label)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(display.tone.color)
        }
    }
}

private struct TransferRow: View {
    let transfer: TransferItem

    var body: some View {
        HStack(spacing: 10) {
            // Direction badge (↑ accent / ↓ green)
            Image(systemName: transfer.direction.symbolName)
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(transfer.direction.tint)
                .frame(width: 24, height: 24)
                .background(transfer.direction.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel(transfer.direction == .upload ? "Uploading" : "Downloading")

            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.name)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Surface.fg)
                Text("\(transfer.location) · \(Format.size(transfer.sizeBytes))")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Surface.fg2)
            }

            Spacer()

            MiniProgressBar(
                progress: transfer.progress,
                tint: transfer.isDone ? Palette.success : transfer.direction.tint,
                label: "\(transfer.name) transfer progress",
                indeterminate: transfer.isIndeterminate
            )
            .frame(width: 90)

            Group {
                if transfer.isDone {
                    Text("Done")
                        .foregroundStyle(Palette.success)
                } else if transfer.isIndeterminate {
                    // No percent exists on this channel — the word is the
                    // whole truth we have.
                    Text(transfer.direction == .upload ? "Uploading…" : "Downloading…")
                        .foregroundStyle(transfer.direction.tint)
                } else {
                    Text("\(Int((transfer.progress * 100).rounded()))%")
                        .foregroundStyle(transfer.direction.tint)
                        .monospacedDigit()
                }
            }
            .scaledFont(size: 12, weight: .bold)
            .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(transfer.direction == .upload ? "Uploading" : "Downloading") \(transfer.name), \(transfer.location), \(Format.size(transfer.sizeBytes)), \(transfer.isDone ? "done" : transfer.isIndeterminate ? "in progress" : "\(Int((transfer.progress * 100).rounded())) percent")"
        )
    }
}
