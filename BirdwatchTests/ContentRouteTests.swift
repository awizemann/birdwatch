import Testing
@testable import Birdwatch
import Foundation

/// Pausing before the first snapshot ever landed used to leave a spinner on
/// screen forever — a claim that work was in flight when monitoring had
/// stopped (C1). The route is derived here rather than inline in the view so
/// that claim is testable: no route may show a spinner while paused.
@MainActor
struct ContentRouteTests {
    private func store(paused: Bool, loaded: Bool) async -> SyncStore {
        let store = SyncStore(source: StubSyncSource(snapshot: .minimal()))
        if loaded { await store.refresh(force: true) }
        if paused { store.togglePauseAll() }
        return store
    }

    @Test("Paused before the first load routes to the paused state, never the spinner")
    func pausedBeforeFirstLoadIsNotLoading() async {
        let store = await store(paused: true, loaded: false)
        #expect(store.isPausedBeforeFirstLoad)
        let route = ContentRoute(store: store)
        #expect(route == .pausedBeforeFirstLoad)
        // The falsification condition, stated directly: the spinner branch
        // must not be reachable while monitoring is paused.
        #expect(route.showsSpinner == false)
    }

    @Test("A genuine first load still shows the spinner")
    func unpausedFirstLoadStillSpins() async {
        let store = await store(paused: false, loaded: false)
        let route = ContentRoute(store: store)
        #expect(route == .loading)
        #expect(route.showsSpinner)
    }

    @Test("Pausing after data has loaded keeps showing the data, not the paused state")
    func pausingAfterLoadKeepsContent() async {
        let store = await store(paused: true, loaded: true)
        #expect(store.isGloballyPaused)
        #expect(store.isPausedBeforeFirstLoad == false)
        #expect(ContentRoute(store: store) == .view(.overview))
    }

    @Test("Resuming from the paused state leaves it for real content")
    func resumeLeavesThePausedState() async {
        let store = await store(paused: true, loaded: false)
        #expect(ContentRoute(store: store) == .pausedBeforeFirstLoad)
        // The store kicks off the catch-up refresh on resume; await it rather
        // than sleeping (C8).
        store.togglePauseAll()
        await store.pendingResumeRefresh?.value
        #expect(store.hasLoaded)
        #expect(ContentRoute(store: store) == .view(.overview))
    }

    @Test("Detail routes still win once data has loaded")
    func detailRoutesUnchanged() async {
        let store = await store(paused: false, loaded: true)
        store.conflictIssueID = "conflict-1"
        #expect(ContentRoute(store: store) == .conflict("conflict-1"))
        store.conflictIssueID = nil
        store.detailAppID = "photos"
        #expect(ContentRoute(store: store) == .app("photos"))
        // Each route animates on a distinct key.
        #expect(ContentRoute.pausedBeforeFirstLoad.key != ContentRoute.loading.key)
    }
}
