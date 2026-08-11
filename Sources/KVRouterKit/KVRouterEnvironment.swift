//
//  KVRouterEnvironment.swift
//  KVRouterKit
//
//  Created by Khanh Vu.
//

import SwiftUI

// MARK: - ================================
// MARK: Router Environment
// MARK: ================================

/// Environment key for accessing the router.
///
/// `KVAppRouter` is `@MainActor` while `defaultValue` is nonisolated;
/// SwiftUI only reads environment values on the main thread, so assuming
/// main-actor isolation here is safe.
private struct KVAppRouterKey: EnvironmentKey {
    static let defaultValue: KVAppRouter = MainActor.assumeIsolated {
        KVAppRouter(middlewares: [])
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

    /// The current app router.
    ///
    /// **Usage:**
    /// ```swift
    /// struct MyView: View {
    ///     @Environment(\.router) private var router
    ///
    ///     var body: some View {
    ///         Button("Go to Profile") {
    ///             router.push(.appFeature("profile"))
    ///         }
    ///     }
    /// }
    /// ```
    var router: KVAppRouter {
        get { self[KVAppRouterKey.self] }
        set { self[KVAppRouterKey.self] = newValue }
    }
}

/// View extension for injecting router into environment.
public extension View {

    /// Inject the app router into the view's environment.
    /// - Parameter router: The router instance to inject.
    /// - Returns: A view with the router in its environment.
    func appRouter(_ router: KVAppRouter) -> some View {
        environment(\.router, router)
    }
}
