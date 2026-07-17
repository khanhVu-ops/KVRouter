//
//  KVRouterEnvironment.swift
//  KVRouter
//
//  Created by Khanh Vu.
//

import SwiftUI

// MARK: - ================================
// MARK: Router Environment
// MARK: ================================

/// Environment key for accessing the router.
private struct KVAppRouterKey: EnvironmentKey {
    static let defaultValue: KVAppRouter = KVAppRouter(middlewares: [])
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
