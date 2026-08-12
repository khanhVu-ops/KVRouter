//
//  KVRoutingPortTests.swift
//  KVRouterKit
//
//  Phase 1 DoD: a ViewModel depends on `KVRouting` only, is asserted against
//  `KVRouterSpy`, and drives the real `KVAppRouter` unchanged.
//

import XCTest
import KVRouterCore
import KVRouterTesting
@testable import KVRouterKit

// MARK: - Test doubles for app code

/// Stands in for a real ViewModel. Note what it does *not* import: SwiftUI,
/// UIKit, or `KVAppRouter`. Only the port.
@MainActor
private final class ProductListViewModel {
    private let router: any KVRouting

    init(router: any KVRouting) {
        self.router = router
    }

    var canGoBack: Bool { router.stackDepth > 0 }

    func didTapProduct(_ id: Int) {
        router.push(TestRoute.screen("product-\(id)"))
    }

    func didTapBack() {
        router.pop()
    }
}

private enum SampleRoute: KVRoute {
    case detail(id: Int)
    case cart
}

private enum OtherRoute: KVRoute {
    case detail(id: Int)
}

// MARK: - Tests

@MainActor
final class KVRoutingPortTests: XCTestCase {

    // MARK: - Interchangeability (the point of the phase)

    func testViewModelNavigatesThroughSpy() {
        let router = KVRouterSpy()
        let sut = ProductListViewModel(router: router)

        sut.didTapProduct(42)

        XCTAssertEqual(
            router.operations,
            [.push(AnyKVRoute(TestRoute.screen("product-42")))]
        )
        XCTAssertEqual(router.stackDepth, 1)
    }

    /// The same ViewModel, unchanged, against the real router. If this and the
    /// test above ever disagree, the spy has drifted from production behaviour.
    func testSameViewModelDrivesRealRouter() async {
        let router = KVAppRouter()
        let sut = ProductListViewModel(router: router)

        sut.didTapProduct(42)
        await router.settle()

        XCTAssertEqual(router.path, [.screen("product-42")])
        XCTAssertEqual(router.stackDepth, 1)
    }

    func testPopThroughPortOnBothImplementations() async {
        let spy = KVRouterSpy()
        let real = KVAppRouter()

        for router in [spy, real] as [any KVRouting] {
            let sut = ProductListViewModel(router: router)
            XCTAssertFalse(sut.canGoBack)

            sut.didTapProduct(1)
            sut.didTapProduct(2)
            sut.didTapBack()

            if let real = router as? KVAppRouter { await real.settle() }
            XCTAssertEqual(router.stackDepth, 1)
            XCTAssertTrue(sut.canGoBack)
        }
    }

    // MARK: - settle()

    /// `settle()` exists so tests stop polling. The rest of the suite waits in
    /// 10ms increments with a 2s timeout; this needs neither.
    func testSettleAwaitsQueuedOperations() async {
        let router = KVAppRouter()

        router.push(TestRoute.screen("a"))
        router.push(TestRoute.screen("b"))
        router.push(TestRoute.screen("c"))
        await router.settle()

        XCTAssertEqual(
            router.path,
            [.screen("a"), .screen("b"), .screen("c")]
        )
    }

    func testSettleReturnsImmediatelyWhenQueueIsEmpty() async {
        let router = KVAppRouter()
        await router.settle()
        XCTAssertTrue(router.path.isEmpty)
    }

    func testSettleAfterMixedOperations() async {
        let router = KVAppRouter()

        router.push(TestRoute.screen("a"))
        router.popToRoot()
        router.push(TestRoute.screen("b"))
        await router.settle()

        XCTAssertEqual(router.path, [.screen("b")])
    }

    // MARK: - AnyKVRoute

    func testAnyKVRouteEqualityIsTypeAware() {
        XCTAssertEqual(
            AnyKVRoute(SampleRoute.detail(id: 1)),
            AnyKVRoute(SampleRoute.detail(id: 1))
        )
        XCTAssertNotEqual(
            AnyKVRoute(SampleRoute.detail(id: 1)),
            AnyKVRoute(SampleRoute.detail(id: 2))
        )
        // Same case name, same payload, different type — must not collide.
        XCTAssertNotEqual(
            AnyKVRoute(SampleRoute.detail(id: 1)),
            AnyKVRoute(OtherRoute.detail(id: 1))
        )
    }

    func testAnyKVRouteHashingMatchesEquality() {
        let set: Set<AnyKVRoute> = [
            AnyKVRoute(SampleRoute.detail(id: 1)),
            AnyKVRoute(SampleRoute.detail(id: 1)),
            AnyKVRoute(OtherRoute.detail(id: 1))
        ]
        XCTAssertEqual(set.count, 2)
    }

    func testAnyKVRouteUnwrapsConcreteType() {
        let erased = AnyKVRoute(SampleRoute.cart)
        XCTAssertEqual(erased.unwrap(SampleRoute.self), .cart)
        XCTAssertNil(erased.unwrap(OtherRoute.self))
    }

    func testRestorationIDDefaultsToTypeName() {
        struct Restorable: KVRestorableRoute {
            let id: Int
        }
        XCTAssertTrue(Restorable.restorationID.hasSuffix("Restorable"))
    }

    // MARK: - Spy fidelity

    /// The port is route-agnostic — spy and real router both take any `KVRoute`.
    func testSpyAcceptsCustomRouteTypes() {
        let router = KVRouterSpy()

        router.push(SampleRoute.detail(id: 7))
        router.push(SampleRoute.cart)

        XCTAssertEqual(router.pushed(SampleRoute.self), [.detail(id: 7), .cart])
        XCTAssertEqual(router.topRoute as? SampleRoute, .cart)
    }

    func testSpyTruncatesStackOnPopTo() {
        let router = KVRouterSpy(stack: [
            SampleRoute.detail(id: 1),
            SampleRoute.cart,
            SampleRoute.detail(id: 2)
        ])

        router.popTo(SampleRoute.cart)

        XCTAssertEqual(router.stackDepth, 2)
        XCTAssertEqual(router.topRoute as? SampleRoute, .cart)
    }

    func testSpyPopToUnknownRouteLeavesStackIntact() {
        let router = KVRouterSpy(stack: [SampleRoute.cart])

        router.popTo(OtherRoute.detail(id: 99))

        XCTAssertEqual(router.stackDepth, 1)
        XCTAssertEqual(router.operations, [.popTo(AnyKVRoute(OtherRoute.detail(id: 99)))])
    }

    func testSpyPopCountClampsToStackDepth() {
        let router = KVRouterSpy(stack: [SampleRoute.cart])

        router.pop(count: 5)

        XCTAssertEqual(router.stackDepth, 0)
        XCTAssertEqual(router.operations, [.popCount(5)])
    }

    func testSpyPopToWhereUsesPredicate() {
        let router = KVRouterSpy(stack: [
            SampleRoute.detail(id: 1),
            SampleRoute.cart,
            SampleRoute.detail(id: 2)
        ])

        router.popTo { ($0 as? SampleRoute) == .cart }

        XCTAssertEqual(router.stackDepth, 2)
        XCTAssertEqual(router.operations, [.popToMatching])
    }

    func testSpyResetClearsEverything() {
        let router = KVRouterSpy(stack: [SampleRoute.cart])
        router.push(SampleRoute.detail(id: 1))

        router.reset()

        XCTAssertTrue(router.operations.isEmpty)
        XCTAssertEqual(router.stackDepth, 0)
        XCTAssertNil(router.topRoute)
    }
}
