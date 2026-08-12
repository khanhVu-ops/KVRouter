//
//  KVRouterEnvironment.swift
//  KVRouterKit
//
//  Created by Khanh Vu.
//

import SwiftUI
import KVRouterCore

// MARK: - ================================
// MARK: Router Environment
// MARK: ================================

/// Stands in when `@Environment(\.router)` is read outside a ``KVRouterHost``.
///
/// The old default was a real, unhosted ``KVAppRouter``: pushes went into an
/// invisible stack and simply never appeared, with no crash and no log. A
/// no-op that says so is far easier to diagnose.
@MainActor
final class KVNullRouter: KVViewRouting {

    private var hasReported = false

    private func reportMissingHost(_ command: String) {
        guard !hasReported else { return }
        hasReported = true
        assertionFailure(
            """
            \(command) was sent to the placeholder router: this view's \
            @Environment(\\.router) has no KVRouterHost above it, so navigation \
            cannot happen. Wrap the view hierarchy in KVRouterHost, or inject a \
            router with .appRouter(_:).
            """
        )
    }

    // MARK: - KVRouting

    var stackDepth: Int { 0 }
    var topRoute: (any KVRoute)? { nil }
    var routes: [any KVRoute] { [] }

    func push(_ route: any KVRoute) { reportMissingHost("push(\(route))") }
    func replaceTop(with route: any KVRoute) { reportMissingHost("replaceTop") }
    func setPath(_ routes: [any KVRoute]) { reportMissingHost("setPath") }
    func pop() { reportMissingHost("pop()") }
    func pop(count: Int) { reportMissingHost("pop(count:)") }
    func popToRoot() { reportMissingHost("popToRoot()") }
    func popTo(_ route: any KVRoute) { reportMissingHost("popTo(_:)") }
    func popTo(where predicate: @escaping (any KVRoute) -> Bool) {
        reportMissingHost("popTo(where:)")
    }

    // MARK: - KVViewRouting

    func push(_ route: any KVRoute, transition: KVNavigationTransition) {
        reportMissingHost("push(_:transition:)")
    }

    func replaceTop(with route: any KVRoute, transition: KVNavigationTransition) {
        reportMissingHost("replaceTop(with:transition:)")
    }

    func pushView<V: View>(tag: String?, _ build: @escaping () -> V) {
        reportMissingHost("pushView")
    }

    func pushView<V: View>(
        tag: String?,
        transition: KVNavigationTransition,
        _ build: @escaping () -> V
    ) {
        reportMissingHost("pushView(transition:)")
    }

    func replaceTopWithView<V: View>(tag: String?, _ build: @escaping () -> V) {
        reportMissingHost("replaceTopWithView")
    }

    func popTo(tag: String) { reportMissingHost("popTo(tag:)") }

    func popTo<V: View>(_ viewType: V.Type) { reportMissingHost("popTo(_:)") }
}

/// `defaultValue` is nonisolated while the routers are `@MainActor`; SwiftUI
/// only reads environment values on the main thread, so assuming main-actor
/// isolation here is safe.
private struct KVAppRouterKey: EnvironmentKey {
    static let defaultValue: any KVViewRouting = MainActor.assumeIsolated {
        KVNullRouter()
    }
}

private struct KVTransitionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private struct KVTransitionSourceRegistryKey: EnvironmentKey {
    static let defaultValue: KVTransitionSourceRegistry? = nil
}

extension EnvironmentValues {
    var kvTransitionNamespace: Namespace.ID? {
        get { self[KVTransitionNamespaceKey.self] }
        set { self[KVTransitionNamespaceKey.self] = newValue }
    }

    var kvTransitionSourceRegistry: KVTransitionSourceRegistry? {
        get { self[KVTransitionSourceRegistryKey.self] }
        set { self[KVTransitionSourceRegistryKey.self] = newValue }
    }
}

/// Environment value extension for router access.
public extension EnvironmentValues {

    /// The current router, as the view-layer port.
    ///
    /// Typed as ``KVViewRouting`` rather than `KVAppRouter`, so view code gets
    /// `pushView { }` and the transition overloads while staying mockable.
    /// ViewModels should take `any KVRouting` through their initializer instead
    /// of reaching into the environment.
    ///
    /// **Usage:**
    /// ```swift
    /// struct MyView: View {
    ///     @Environment(\.router) private var router
    ///
    ///     var body: some View {
    ///         Button("Go to Profile") {
    ///             router.push(ProfileRoute.me)
    ///         }
    ///     }
    /// }
    /// ```
    var router: any KVViewRouting {
        get { self[KVAppRouterKey.self] }
        set { self[KVAppRouterKey.self] = newValue }
    }
}

/// View extension for injecting router into environment.
public extension View {

    /// Inject the router into the view's environment.
    /// - Parameter router: The router instance to inject.
    /// - Returns: A view with the router in its environment.
    func appRouter(_ router: any KVViewRouting) -> some View {
        environment(\.router, router)
    }
}
