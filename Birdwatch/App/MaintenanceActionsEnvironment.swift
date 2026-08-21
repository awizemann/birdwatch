import SwiftUI

/// Injects the app's single `MaintenanceActions` actor into the view tree.
///
/// Diagnostics used to hold its own `private let maintenance =
/// MaintenanceActions()`. A `View` is a value SwiftUI re-creates on every
/// invalidation, so that minted a new actor each time and an in-flight restart
/// ended up owned by an instance no later body could reach. One instance,
/// created by `BirdwatchApp` and passed down here, gives the operations a
/// single owner for the app's lifetime.
///
/// The default value exists only so previews and any view rendered outside the
/// app scene still compile; the real one always comes from `BirdwatchApp`.
/// Constructing it is pure — the actor allocates a `ProcessRunner` and nothing
/// else, so no Process runs and no disk is touched (C4).
private struct MaintenanceActionsKey: EnvironmentKey {
    nonisolated static let defaultValue = MaintenanceActions()
}

extension EnvironmentValues {
    var maintenanceActions: MaintenanceActions {
        get { self[MaintenanceActionsKey.self] }
        set { self[MaintenanceActionsKey.self] = newValue }
    }
}
