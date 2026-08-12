//
//  KVRouting.swift
//  KVRouterCore
//

import Foundation

/// Navigation commands, with no SwiftUI in sight.
///
/// This is the port a ViewModel, presenter, or use case should depend on. It
/// carries stack commands only — no view builders, no transitions, no modals:
///
/// - Building a view is the View layer's job, so `pushView { }` lives on
///   `KVViewRouting` in `KVRouterKit` instead.
/// - Choosing an animation is a presentation decision, so the
///   `transition:` overloads live there too.
/// - Modals are handled by SwiftUI's own `.sheet` / `.fullScreenCover`; the
///   router does not manage them.
///
/// ```swift
/// final class ProductListViewModel {
///     private let router: any KVRouting
///     init(router: any KVRouting) { self.router = router }
///
///     func didTapProduct(_ id: Int) {
///         router.push(ShopRoute.productDetail(id: id))
///     }
/// }
/// ```
///
/// Test against `KVRouterSpy` from `KVRouterTesting` — no `KVAppRouter`, no
/// SwiftUI, no simulator machinery.
///
/// `Sendable` costs conformers nothing: they are `@MainActor` classes, which are
/// implicitly `Sendable`. It is required so the existential can be stored in a
/// SwiftUI environment key.
@MainActor
public protocol KVRouting: AnyObject, Sendable {

    // MARK: - State

    /// Number of screens pushed above the root.
    ///
    /// - Important: A snapshot, **not** an observable property. Safe to read
    ///   from a ViewModel; do not drive a SwiftUI `body` from it — see the
    ///   observation notes in `KVAppRouter`.
    var stackDepth: Int { get }

    /// The route currently on top of the stack, or `nil` at the root.
    ///
    /// - Important: A snapshot, not an observable property.
    var topRoute: (any KVRoute)? { get }

    // MARK: - Push

    /// Push a route onto the navigation stack.
    func push(_ route: any KVRoute)

    /// Replace the top route, leaving the rest of the stack untouched.
    func replaceTop(with route: any KVRoute)

    /// Replace the whole stack. Middleware runs for each route in turn.
    func setPath(_ routes: [any KVRoute])

    // MARK: - Pop

    /// Pop the top screen. Middleware can cancel this.
    func pop()

    /// Pop `count` screens, clamped to the current stack depth.
    func pop(count: Int)

    /// Pop every screen above the root.
    func popToRoot()

    /// Pop back to `route`. Does nothing when it is not in the stack.
    func popTo(_ route: any KVRoute)

    /// Pop back to the topmost route matching `predicate`.
    ///
    /// The predicate receives a type-erased route; downcast to inspect it:
    /// ```swift
    /// router.popTo { ($0 as? ShopRoute) == .cart }
    /// ```
    func popTo(where predicate: @escaping (any KVRoute) -> Bool)
}
