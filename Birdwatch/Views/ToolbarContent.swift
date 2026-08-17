import SwiftUI

/// Title-bar cluster: search, notifications bell (badged), Pause/Resume Monitoring.
/// (The design's Light/Dark segmented toggle maps to the system appearance on
/// macOS; the app follows the system rather than shipping its own switch —
/// recorded as a deliberate deviation.)
struct MainToolbar: ToolbarContent {
    @Environment(SyncStore.self) private var store

    var body: some ToolbarContent {
        // Search leads (it belongs with the content), the two controls that act
        // on the whole app sit together on the trailing edge.
        ToolbarItem(placement: .principal) {
            SearchFieldView()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.notificationsPanelOpen.toggle()
            } label: {
                Image(systemName: "bell")
                    .overlay(alignment: .topTrailing) {
                        if store.unreadNotificationCount > 0 {
                            Circle().fill(Palette.error).frame(width: 7, height: 7).offset(x: 2, y: -2)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .accessibilityLabel("Notifications, \(store.unreadNotificationCount) unread")
            .help("Notifications")
            .popover(isPresented: notificationsBinding, arrowEdge: .bottom) {
                NotificationsPanelView()
                    .environment(store) // §7: re-inject into presented content
            }

            // Icon, and the icon shows what the click DOES: a play button when
            // paused, a pause button when running. ⇧⌘P (Commands menu) is
            // unchanged and still drives the same store method.
            Button {
                store.togglePauseAll()
            } label: {
                Image(systemName: store.isGloballyPaused ? "play.circle" : "pause.circle")
            }
            .help(store.isGloballyPaused ? "Resume monitoring" : "Pause monitoring")
            .accessibilityLabel(store.isGloballyPaused ? "Resume monitoring" : "Pause monitoring")
        }
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(get: { store.notificationsPanelOpen }, set: { store.notificationsPanelOpen = $0 })
    }
}

/// Debounced toolbar search (§7): local @State, pushed to the store after 250ms.
struct SearchFieldView: View {
    @Environment(SyncStore.self) private var store
    @State private var draft = ""
    @State private var selectedIndex = 0
    /// Set when the popover is dismissed for reasons other than opening a
    /// result or pressing Escape (e.g. clicking outside); the query text is
    /// deliberately preserved so the user doesn't lose their search.
    @State private var suppressPopover = false

    private var resultsPresented: Binding<Bool> {
        Binding(
            get: { !suppressPopover && store.searchText.count >= 2 && !store.searchResults.isEmpty },
            set: { newValue in if !newValue { suppressPopover = true } }
        )
    }

    var body: some View {
        TextField("Search", text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
            .task(id: draft) {
                suppressPopover = false
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                store.searchText = draft
            }
            .onChange(of: store.searchResults.count) { _, newCount in
                selectedIndex = 0
                if store.searchText.count >= 2 {
                    let text = newCount == 0 ? "No results" : "\(newCount) result\(newCount == 1 ? "" : "s")"
                    AccessibilityNotification.Announcement(text).post()
                }
            }
            .onKeyPress(.downArrow) {
                guard !store.searchResults.isEmpty else { return .ignored }
                selectedIndex = min(selectedIndex + 1, store.searchResults.count - 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard !store.searchResults.isEmpty else { return .ignored }
                selectedIndex = max(selectedIndex - 1, 0)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !draft.isEmpty else { return .ignored }
                store.searchText = ""
                draft = ""
                return .handled
            }
            .onSubmit {
                let results = store.searchResults
                guard !results.isEmpty else { return }
                let index = min(selectedIndex, results.count - 1)
                store.open(results[index].target)
                store.searchText = ""
                draft = ""
            }
            .accessibilityLabel("Search apps, files, folders and activity")
            .popover(isPresented: resultsPresented, arrowEdge: .bottom) {
                SearchResultsList(selectedIndex: selectedIndex, onOpen: {
                    store.searchText = ""
                    draft = ""
                })
                .environment(store) // §7: re-inject into presented content
            }
    }
}

/// Dropdown listing live search matches; clicking a row routes via store.open.
private struct SearchResultsList: View {
    @Environment(SyncStore.self) private var store
    let selectedIndex: Int
    var onOpen: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(store.searchResults.enumerated()), id: \.element.id) { index, result in
                    let isSelected = index == selectedIndex
                    Button {
                        store.open(result.target)
                        onOpen()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: result.symbolName)
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(Palette.accent)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.title)
                                    .scaledFont(size: 13, weight: .semibold)
                                    .foregroundStyle(Surface.fg)
                                    .lineLimit(1)
                                Text(result.subtitle)
                                    .scaledFont(size: 11.5)
                                    .foregroundStyle(Surface.fg2)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? Surface.hover : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(result.title), \(result.subtitle)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(6)
        }
        .frame(width: 300)
        .frame(maxHeight: 320)
    }
}
