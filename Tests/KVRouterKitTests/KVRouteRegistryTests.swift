//
//  KVRouteRegistryTests.swift
//  KVRouterKit
//
//  Written with Swift Testing rather than XCTest. The two coexist in one target,
//  so new tests use `@Test` while the existing XCTest suites stay as they are —
//  rewriting 128 passing tests would be churn for diagnostics alone.
//

import Testing
import SwiftUI
import KVRouterCore
@testable import KVRouterKit

private enum ShopTestRoute: KVRoute {
    case cart
    case detail(id: Int)
}

private enum AuthTestRoute: KVRoute {
    case login
}

/// Mutable counter for escaping closures under `@MainActor`.
@MainActor
private final class Recorder {
    var calls: [String] = []
}

@MainActor
@Suite("Route registry")
struct KVRouteRegistryTests {

    @Test("A registered route type resolves to a destination")
    func resolvesRegisteredType() {
        let registry = KVRouteRegistry()
        registry.register(ShopTestRoute.self) { _ in Text("shop") }

        #expect(registry.view(for: ShopTestRoute.cart) != nil)
        #expect(registry.view(for: ShopTestRoute.detail(id: 1)) != nil)
    }

    @Test("An unregistered route type resolves to nil")
    func unregisteredTypeResolvesToNil() {
        let registry = KVRouteRegistry()
        #expect(registry.view(for: ShopTestRoute.cart) == nil)
    }

    /// Lookup is keyed on the concrete type, so registering one route type must
    /// not accidentally answer for another.
    @Test("Registration is scoped to one concrete type")
    func registrationIsScopedToItsType() {
        let registry = KVRouteRegistry()
        registry.register(ShopTestRoute.self) { _ in Text("shop") }

        #expect(registry.view(for: AuthTestRoute.login) == nil)
    }

    @Test("The route value reaches the destination builder")
    func passesTheRouteToTheBuilder() {
        let registry = KVRouteRegistry()
        let recorder = Recorder()
        registry.register(ShopTestRoute.self) { route in
            recorder.calls.append("\(route)")
            return Text("shop")
        }

        _ = registry.view(for: ShopTestRoute.detail(id: 7))

        #expect(recorder.calls == ["detail(id: 7)"])
    }

    @Test("Re-registering a type replaces the destination")
    func reRegisteringReplacesTheDestination() {
        let registry = KVRouteRegistry()
        let recorder = Recorder()
        registry.register(ShopTestRoute.self) { _ in
            recorder.calls.append("first")
            return Text("first")
        }
        registry.register(ShopTestRoute.self) { _ in
            recorder.calls.append("second")
            return Text("second")
        }

        _ = registry.view(for: ShopTestRoute.cart)

        #expect(recorder.calls == ["second"])
    }

    /// `body` re-runs on every render, so registration must not: rebuilding the
    /// closures each time would churn the environment for nothing.
    @Test("configureOnce runs exactly once per registry")
    func configureOnceRunsOnce() {
        let registry = KVRouteRegistry()
        let recorder = Recorder()

        for _ in 0..<3 {
            registry.configureOnce { _ in recorder.calls.append("configured") }
        }

        #expect(recorder.calls == ["configured"])
    }
}

/// Compile-time assertion that a transition can live in a `Sendable` type — the
/// whole point of dropping `@MainActor` from it. If the conformance regresses,
/// this file stops building.
private struct TransitionBox: Sendable {
    let transition: KVNavigationTransition
}

@Suite("Transition is Sendable")
struct KVNavigationTransitionSendableTests {

    @Test("A transition crosses isolation without losing its kind")
    func crossesIsolation() async {
        let box = TransitionBox(transition: .zoom(sourceID: "card"))

        let kind = await Task.detached { box.transition.debugKind }.value

        #expect(kind == .zoom)
    }

    /// `.system` and friends are non-isolated globals now, so reading one off the
    /// main actor must not need an `await`.
    @Test("Static transitions are reachable off the main actor")
    func staticsAreNonIsolated() async {
        let kind = await Task.detached { KVNavigationTransition.depth.debugKind }.value

        #expect(kind == .depth)
    }
}

@MainActor
@Suite("Route-level default transition")
struct KVRouteTransitionTests {

    @Test("register(_:transition:) declares both view and transition")
    func registersViewAndTransition() {
        let registry = KVRouteRegistry()
        registry.register(ShopTestRoute.self, transition: .fade) { _ in
            Text("shop")
        }

        #expect(registry.view(for: ShopTestRoute.cart) != nil)
        #expect(registry.transition(for: ShopTestRoute.cart)?.debugKind == .fade)
    }

    @Test("A route type with no declared transition resolves to nil")
    func undeclaredTransitionIsNil() {
        let registry = KVRouteRegistry()
        registry.register(ShopTestRoute.self) { _ in Text("shop") }

        #expect(registry.transition(for: ShopTestRoute.cart) == nil)
    }

    @Test("Transitions are scoped to one concrete type")
    func transitionIsScopedToItsType() {
        let registry = KVRouteRegistry()
        registry.register(ShopTestRoute.self, transition: .fade) { _ in
            Text("shop")
        }

        #expect(registry.transition(for: AuthTestRoute.login) == nil)
    }

    /// The per-value form is what lets one route type's cases differ, and
    /// returning `nil` for a case is how it opts back into the host default.
    @Test("A per-value transition varies by case")
    func perValueTransitionVariesByCase() {
        let registry = KVRouteRegistry()
        registry.registerTransition(ShopTestRoute.self) { route in
            switch route {
            case .detail: .depth
            case .cart: nil
            }
        }

        #expect(registry.transition(for: ShopTestRoute.detail(id: 1))?.debugKind == .depth)
        #expect(registry.transition(for: ShopTestRoute.cart) == nil)
    }

    /// Registering a transition must not imply a destination, so the two calls
    /// can be made in either order without one clobbering the other.
    @Test("Declaring a transition leaves the destination alone")
    func transitionRegistrationIsIndependent() {
        let registry = KVRouteRegistry()
        registry.registerTransition(ShopTestRoute.self) { _ in .fade }
        registry.register(ShopTestRoute.self) { _ in Text("shop") }

        #expect(registry.view(for: ShopTestRoute.cart) != nil)
        #expect(registry.transition(for: ShopTestRoute.cart)?.debugKind == .fade)
    }
}

@MainActor
@Suite("Dynamic view route")
struct KVDynamicViewRouteTests {

    /// Identity is the id alone: tag and type name describe the same screen, so
    /// two references to one screen must not compare unequal.
    @Test("Identity ignores tag and view type")
    func identityIsTheIDAlone() {
        let id = UUID()
        let a = KVDynamicViewRoute(id: id, tag: "a", typeName: "A")
        let b = KVDynamicViewRoute(id: id, tag: "b", typeName: "B")

        #expect(a == b)
        #expect(AnyKVRoute(a) == AnyKVRoute(b))
        #expect(Set([AnyKVRoute(a), AnyKVRoute(b)]).count == 1)
    }

    @Test("Different screens stay distinct")
    func differentIDsAreDistinct() {
        let a = KVDynamicViewRoute(id: UUID(), tag: nil, typeName: "A")
        let b = KVDynamicViewRoute(id: UUID(), tag: nil, typeName: "A")

        #expect(a != b)
    }

    /// Its view is a closure held in memory, so it must never claim to survive
    /// persistence.
    @Test("Not restorable")
    func isNotRestorable() {
        #expect(!(KVDynamicViewRoute.self is any KVRestorableRoute.Type))
    }
}
