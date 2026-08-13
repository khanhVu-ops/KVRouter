//
//  KVUnhostedRouter.swift
//  KVRouterCore
//

import Foundation

// MARK: - ================================
// MARK: Placeholder Router
// MARK: ================================

/// Stands in for a real router until the composition root installs one.
///
/// A DI container needs a value for `any KVRouting` before anything is wired,
/// and the two obvious candidates are both bad: a real router with no host
/// swallows every push into an invisible stack, and a silent no-op looks like a
/// broken button and gets debugged from the wrong end. This one reports instead
/// — `assertionFailure` on the first command it receives, naming the command, so
/// a debug build stops at the missing wiring rather than at the symptom.
///
/// Only the first command reports. A missing installation usually shows up as a
/// burst of navigation, and one clear stop is more useful than a stream.
///
/// ```swift
/// enum AppDependencies {
///     static var router: any KVRouting = KVUnhostedRouter()
/// }
/// ```
///
/// Release builds are unaffected by the assertion and every command is a no-op,
/// which is the same trade `KVRouterKit` makes for a view whose
/// `@Environment(\.router)` has no host above it.
///
/// - Note: For a router that *records* commands rather than complaining about
///   them, use `KVRouterSpy` from `KVRouterTesting` — that is a test double and
///   belongs in test targets, not in an app's dependency graph.
@MainActor
public final class KVUnhostedRouter: KVRouting {

    private var hasReported = false

    public init() {}

    // MARK: - State

    public var stackDepth: Int { 0 }
    public var topRoute: (any KVRoute)? { nil }
    public var routes: [any KVRoute] { [] }

    // MARK: - Push

    public func push(_ route: any KVRoute) {
        report("push(\(type(of: route)))")
    }

    public func replaceTop(with route: any KVRoute) {
        report("replaceTop(with: \(type(of: route)))")
    }

    public func setPath(_ routes: [any KVRoute]) {
        report("setPath(_:) with \(routes.count) route(s)")
    }

    // MARK: - Pop

    public func pop() {
        report("pop()")
    }

    public func pop(count: Int) {
        report("pop(count: \(count))")
    }

    public func popToRoot() {
        report("popToRoot()")
    }

    public func popTo(_ route: any KVRoute) {
        report("popTo(\(type(of: route)))")
    }

    public func popTo(where predicate: @escaping (any KVRoute) -> Bool) {
        report("popTo(where:)")
    }

    // MARK: - Reporting

    private func report(_ command: String) {
        guard !hasReported else { return }
        hasReported = true
        assertionFailure(
            """
            \(command) was sent to KVUnhostedRouter: no router has been \
            installed, so navigation cannot happen. Assign the real router \
            (KVAppRouter, or whatever your composition root builds) to the \
            dependency this object is standing in for.
            """
        )
    }
}
