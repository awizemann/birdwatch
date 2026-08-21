import SwiftUI

/// Shown where a spinner used to be when monitoring was paused before the
/// first snapshot ever landed.
///
/// A ProgressView there claimed work that is not happening: paused means
/// Birdwatch has stopped watching, so nothing is loading and nothing will
/// until the user resumes (C1). This says exactly that, and carries the
/// resume control so the state is not a dead end.
struct MonitoringPausedState: View {
    @Environment(SyncStore.self) private var store
    /// The menu-bar popover is 328pt wide and cannot afford the full layout.
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            Image(systemName: "pause.circle.fill")
                .scaledFont(size: compact ? 26 : 40)
                .foregroundStyle(Palette.warning)
                .accessibilityHidden(true)

            Text("Monitoring paused")
                .scaledFont(size: compact ? 13 : 16, weight: .bold)
                .foregroundStyle(Surface.fg)

            Text("Birdwatch isn't watching iCloud right now, so it has nothing to show yet. Resume to load the current state.")
                .scaledFont(size: compact ? 11.5 : 13)
                .foregroundStyle(Surface.fg2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: compact ? 260 : 380)

            Button("Resume Monitoring") {
                store.togglePauseAll()
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .controlSize(compact ? .small : .regular)
            .padding(.top, 2)
        }
        .padding(compact ? 16 : 32)
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
        // One element that says "paused", never "loading": the spinner this
        // replaces read as busy to VoiceOver while nothing was running.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Monitoring paused")
        .accessibilityValue("Birdwatch is not watching iCloud. Resume monitoring to load the current state.")
    }
}
