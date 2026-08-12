//
//  KVAppRouter+KVRouting.swift
//  KVRouterKit
//
//  Wires the concrete router to the `KVRouting` port so a ViewModel can depend
//  on the port and be tested against `KVRouterSpy`.
//

import SwiftUI
import KVRouterCore

// MARK: - ================================
// MARK: Transitional Route Conformance
// MARK: ================================

/// Scaffolding, not a compatibility shim: it lets ``KVAppRouter`` satisfy
/// ``KVRouting`` while the stack is still built on ``KVAppRoute``. Phase 3
/// replaces the stack with `AnyKVRoute` and deletes ``KVAppRoute`` — this
/// conformance goes with it.
extension KVAppRoute: KVRoute {}

// MARK: - ================================
// MARK: KVRouting Conformance
// MARK: ================================

extension KVAppRouter: KVRouting {

    // MARK: - State

    public var stackDepth: Int {
        navigationEntries.count
    }

    public var topRoute: (any KVRoute)? {
        navigationEntries.last?.route
    }

    // MARK: - Push

    public func push(_ route: any KVRoute) {
        guard let route = Self.appRoute(from: route) else { return }
        push(route)
    }

    public func replaceTop(with route: any KVRoute) {
        guard let route = Self.appRoute(from: route) else { return }
        replaceTop(with: route)
    }

    public func setPath(_ routes: [any KVRoute]) {
        setPath(routes.compactMap(Self.appRoute(from:)))
    }

    // MARK: - Pop

    public func popTo(_ route: any KVRoute) {
        guard let route = Self.appRoute(from: route) else { return }
        popTo(route)
    }

    public func popTo(where predicate: @escaping (any KVRoute) -> Bool) {
        popTo(where: { (route: KVAppRoute) in predicate(route) })
    }

    // `pop()`, `pop(count:)` and `popToRoot()` carry no route, so the
    // declarations on `KVAppRouter` satisfy the protocol as they stand.

    // MARK: - Bridging

    /// Narrows a type-erased route to the enum the stack is still built on.
    ///
    /// Until Phase 3 lands, ``KVAppRoute`` is the only concrete route the
    /// router can store. Anything else is a programmer error rather than a
    /// runtime condition to absorb, hence the assertion: silently dropping the
    /// navigation would be far harder to diagnose than a debug crash.
    private static func appRoute(from route: any KVRoute) -> KVAppRoute? {
        if let route = route as? KVAppRoute { return route }
        assertionFailure(
            """
            KVAppRouter cannot yet route \(type(of: route)). Until the typed \
            route model lands, only KVAppRoute values can be pushed through \
            the KVRouting port.
            """
        )
        return nil
    }
}
