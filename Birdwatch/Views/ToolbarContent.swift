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
        // Leading placement: the field sits at the left of the content toolbar,
        // right after the sidebar toggle, rather than centered in the title bar.
        ToolbarItem(placement: .navigation) {
            SearchFieldView()
        }

        // With a hidden title bar the content-column toolbar packs items
        // left-to-right; this flexible spacer is what actually pins the two
        // app-level controls to the trailing edge.
        // NOT ToolbarSpacer on macOS 26+: verified on macOS 27 that
        // `ToolbarSpacer(.flexible)` (automatic or .primaryAction placement)
        // leaves the bell and pause buttons packed against the search field in
        // this hidden-title-bar split view. The principal Spacer still works.
        if #available(macOS 26, *) {
            // On 26+ every toolbar item gets a glass capsule; an empty one
            // showed as a thin stray pill mid-toolbar (visible in Dark Mode).
            ToolbarItem(placement: .principal) {
                Spacer()
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                Spacer()
            }
        }

        ToolbarItem(placement: .primaryAction) {
            notificationsButton
        }

        // Icon, and the icon shows what the click DOES: a play button when
        // paused, a pause button when running. ⇧⌘P (Commands menu) is
        // unchanged and still drives the same store method.
        ToolbarItem(placement: .primaryAction) {
            Button {
                store.togglePauseAll()
            } label: {
                Image(systemName: store.isGloballyPaused ? "play.circle" : "pause.circle")
            }
            .help(store.isGloballyPaused ? "Resume monitoring" : "Pause monitoring")
            .accessibilityLabel(store.isGloballyPaused ? "Resume monitoring" : "Pause monitoring")
        }
    }

    @ViewBuilder
    private var notificationsButton: some View {
        let unread = store.unreadNotificationCount
        let button = Button {
            store.notificationsPanelOpen.toggle()
        } label: {
            if #available(macOS 26, *) {
                Image(systemName: "bell")
            } else {
                // Pre-26 toolbars don't draw `.badge`, so the unread mark is
                // hand-drawn there.
                Image(systemName: "bell")
                    .overlay(alignment: .topTrailing) {
                        if unread > 0 {
                            Circle().fill(Palette.error).frame(width: 7, height: 7).offset(x: 2, y: -2)
                                .accessibilityHidden(true)
                        }
                    }
            }
        }
        .accessibilityLabel("Notifications, \(unread) unread")
        .help("Notifications")
        .popover(isPresented: notificationsBinding, arrowEdge: .bottom) {
            NotificationsPanelView()
                .environment(store) // §7: re-inject into presented content
        }

        if #available(macOS 26, *) {
            // The system toolbar badge: drawn on the glass, sized and tinted
            // by the system. 0 shows no badge. The spoken count stays in the
            // label above.
            button.badge(unread)
        } else {
            button
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
        // Idiomatic macOS search look: magnifier + plain field in a rounded
        // capsule. The prefix icon supplies the leading inset, so the
        // placeholder is never flush against the field edge.
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(Surface.fg3)
                .accessibilityHidden(true)

            TextField("Search", text: $draft)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search apps, files, folders and activity")
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        // No filled background: the toolbar item supplies its own chrome, and a
        // second fill rendered as a grey box inside a box. Before macOS 26 a
        // hairline border alone reads as a field; on 26+ the item already sits
        // in a Liquid Glass capsule, and the border drew a box inside it.
        .modifier(PreGlassFieldBorder())
        .frame(width: 220)
            .task(id: draft) {
                suppressPopover = false
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                store.searchText = draft
            }
            .onChange(of: store.searchResults.count) { _, newCount in
                selectedIndex = 0
                if store.searchText.count >= 2 {
                    let text = newCount == 0 ? "No results" : Plural.count(newCount, "result")
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
            .popover(isPresented: resultsPresented, arrowEdge: .bottom) {
                SearchResultsList(selectedIndex: selectedIndex, onOpen: {
                    store.searchText = ""
                    draft = ""
                })
                .environment(store) // §7: re-inject into presented content
            }
    }
}

/// The search field's hairline border, drawn only where the toolbar does not
/// already give the item its own glass capsule (before macOS 26).
private struct PreGlassFieldBorder: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
        } else {
            content.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Surface.cardLine, lineWidth: 0.5))
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
