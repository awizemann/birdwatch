import Foundation
@testable import Birdwatch

/// The ONE place the test bundle builds an `IssueItem`.
///
/// Every suite used to call the memberwise initializer through its own local
/// helper, so adding a field to the DTO broke five files at once — the typed
/// `action:` change was rebased three times for exactly this reason. A new
/// field now costs one edit here, and suites keep their own thin wrappers so
/// each reads in its own vocabulary.
///
/// `nonisolated` because the bundle defaults to MainActor isolation while
/// `IssueItem` is a plain Sendable value: a nonisolated factory can be called
/// from a nonisolated fake or an off-main context without hopping (C6).
nonisolated enum TestIssues {

    /// - Parameter action: deliberately WITHOUT a default, mirroring the DTO's
    ///   own decision. A test that forgets to say what its issue's button does
    ///   fails to compile rather than silently asserting against `.none`, which
    ///   is the guarantee `IssueItem.action` exists to give (see IssueActionTests).
    /// - Parameter title: defaults to the `id`, which is what most suites want —
    ///   an issue identifiable in a failure message. Pass `""` for the suites
    ///   that assert nothing about it.
    static func make(
        id: String = "issue-x",
        action: IssueAction,
        severity: IssueSeverity = .warning,
        title: String? = nil,
        meta: String = "",
        reason: String = "",
        symbolName: String = "circle",
        appID: String? = nil
    ) -> IssueItem {
        IssueItem(
            id: id,
            severity: severity,
            title: title ?? id,
            meta: meta,
            reason: reason,
            action: action,
            symbolName: symbolName,
            appID: appID
        )
    }
}
