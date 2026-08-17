import SwiftUI

struct NotificationsPanelView: View {
    @Environment(SyncStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notifications")
                    .scaledFont(size: 13.5, weight: .bold)
                    .foregroundStyle(Surface.fg)
                Spacer()
                Button("Mark all read") {
                    store.markAllNotificationsRead()
                }
                .buttonStyle(.link)
                .scaledFont(size: 12, weight: .semibold)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider().overlay(Surface.cardLine)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(store.notifications.enumerated()), id: \.element.id) { index, notification in
                        if index > 0 { Divider().overlay(Surface.cardLine) }
                        row(notification)
                    }
                }
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 322)
        .background(Surface.card)
    }

    private func row(_ notification: AppNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: notification.severity.tint)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Surface.fg)
                Text(notification.detail)
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Surface.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            RelativeTimeText(date: notification.date)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(notification.isRead ? Color.clear : Surface.hover)
        .opacity(notification.isRead ? 0.75 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: notification))
    }

    /// Severity and unread state reach VoiceOver, not just the color dot.
    private func accessibilityLabel(for notification: AppNotification) -> String {
        var parts = ["\(notification.severity.pillLabel): \(notification.title)"]
        if !notification.isRead { parts.append("unread") }
        parts.append(notification.detail)
        return parts.joined(separator: ", ")
    }
}
