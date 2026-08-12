//
//  KVRouteRegistry.swift
//  KVRouterKit
//

import SwiftUI
import KVRouterCore

/// Maps route types to their destination views.
///
/// This is the seam that keeps routes free of SwiftUI: a feature module declares
/// `enum ShopRoute: KVRoute { … }` with no view in sight, and the composition
/// root says what each case renders as.
///
/// ```swift
/// KVRouterHost(router: router) { HomeView() }
///     .kvRoutes { routes in
///         routes.register(ShopRoute.self) { route in
///             switch route {
///             case .productDetail(let id): ProductDetailView(id: id)
///             case .cart:                  CartView()
///             }
///         }
///         routes.register(AuthRoute.self) { … }
///     }
/// ```
///
/// A reference type on purpose: it travels through the environment, and a struct
/// would get a fresh identity on every render of the host, invalidating every
/// destination that reads it.
@MainActor
public final class KVRouteRegistry {

    private var builders: [ObjectIdentifier: (any KVRoute) -> AnyView?] = [:]
    private var isConfigured = false

    public init() {}

    /// Register the destination for a route type.
    ///
    /// Registering the same type twice replaces the earlier destination.
    /// - Parameters:
    ///   - type: The route type to handle.
    ///   - destination: Builds the view for a given route value.
    public func register<R: KVRoute, V: View>(
        _ type: R.Type,
        @ViewBuilder destination: @escaping (R) -> V
    ) {
        builders[ObjectIdentifier(R.self)] = { route in
            guard let route = route as? R else { return nil }
            return AnyView(destination(route))
        }
    }

    /// The destination for `route`, or `nil` when its type was never registered.
    func view(for route: any KVRoute) -> AnyView? {
        builders[ObjectIdentifier(type(of: route))]?(route)
    }

    /// Runs `configure` exactly once for this registry instance.
    ///
    /// `body` re-runs on every render, but registration must not: rebuilding the
    /// closures each time would churn the environment for no reason.
    func configureOnce(_ configure: (KVRouteRegistry) -> Void) {
        guard !isConfigured else { return }
        isConfigured = true
        configure(self)
    }
}

// MARK: - ================================
// MARK: Environment Wiring
// MARK: ================================

private struct KVRouteRegistryKey: EnvironmentKey {
    static let defaultValue: KVRouteRegistry? = nil
}

extension EnvironmentValues {
    var kvRouteRegistry: KVRouteRegistry? {
        get { self[KVRouteRegistryKey.self] }
        set { self[KVRouteRegistryKey.self] = newValue }
    }
}

private struct KVRoutesModifier: ViewModifier {
    let configure: (KVRouteRegistry) -> Void

    // Created once per view identity, so the environment carries a stable
    // reference rather than a new registry on every render.
    @State private var registry = KVRouteRegistry()

    func body(content: Content) -> some View {
        registry.configureOnce(configure)
        return content.environment(\.kvRouteRegistry, registry)
    }
}

public extension View {

    /// Declare which view each route type renders as.
    ///
    /// Apply to ``KVRouterHost`` (or any ancestor of it) — destinations read the
    /// registry from the environment.
    /// - Parameter configure: Called once, to register route types.
    func kvRoutes(
        _ configure: @escaping (KVRouteRegistry) -> Void
    ) -> some View {
        modifier(KVRoutesModifier(configure: configure))
    }
}
