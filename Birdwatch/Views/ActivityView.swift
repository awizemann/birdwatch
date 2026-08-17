import SwiftUI

/// Activity — chronological record of sync events (handoff §6).
struct ActivityView: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        ContentColumn {
            ViewHeader(title: MonitorView.activity.title, subtitle: MonitorView.activity.subtitle)

            Card(padding: 0) {
                LazyVStack(spacing: 0) {
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
    }
}
