import SwiftUI

/// Activity — chronological record of sync events (handoff §6).
struct ActivityView: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        ContentColumn {
            ViewHeader(title: MonitorView.activity.title, subtitle: MonitorView.activity.subtitle)

            Card(padding: 0) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.activity.isEmpty {
                        Text(ActivityEmptyState.text(paused: store.isGloballyPaused))
                            .scaledFont(size: 12.5)
                            .foregroundStyle(Surface.fg2)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                    ForEach(Array(store.activity.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider().overlay(Surface.cardLine) }
                        ActivityRow(event: event)
                    }
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: event.symbolName)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(event.kind.tint)
                .frame(width: 30, height: 30)
                .background(event.kind.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .scaledFont(size: 13.5, weight: .semibold)
                    .foregroundStyle(Surface.fg)
                Text(event.detail)
                    .scaledFont(size: 12)
                    .foregroundStyle(Surface.fg2)
            }

            Spacer()

            RelativeTimeText(date: event.date)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel { label in
            // The kind was only the icon and its colour, both hidden from
            // VoiceOver; say it before the title.
            if let kind = event.kind.spokenKind { Text(kind) }
            label
        }
    }
}

extension ActivityKind {
    /// What the row's icon and colour mean, for VoiceOver. nil where the
    /// title already says it ("Uploading …", "Downloading …") or there is
    /// nothing to add (neutral info).
    var spokenKind: String? {
        switch self {
        case .done: "Done"
        case .warning: "Warning"
        case .conflict: "Conflict"
        case .upload, .info: nil
        }
    }
}
