//
//  KVAppRouterTests.swift
//  KVRouterKit
//

import XCTest
import KVRouterCore
import SwiftUI
@testable import KVRouterKit

@MainActor
final class KVAppRouterTests: XCTestCase {

    // Router mutations are scheduled via Task { @MainActor }, so tests poll
    // until the expected state lands (or the timeout expires).
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    // MARK: - Push / Pop

    func testPushAppendsRoute() async {
        let router = KVAppRouter()
        router.push(TestRoute.screen("home"))
        await waitUntil { router.path == [.screen("home")] }
        XCTAssertEqual(router.path, [.screen("home")])
    }

    func testPopRemovesTopRoute() async {
        let router = KVAppRouter()
        router.push(TestRoute.screen("a"))
        router.push(TestRoute.screen("b"))
        await waitUntil { router.path.count == 2 }

        router.pop()
        await waitUntil { router.path.count == 1 }
        XCTAssertEqual(router.path, [.screen("a")])
    }

    func testPopToRootClearsPath() async {
        let router = KVAppRouter()
        router.push(TestRoute.screen("a"))
        router.push(TestRoute.screen("b"))
        router.push(TestRoute.screen("c"))
        await waitUntil { router.path.count == 3 }

        router.popToRoot()
        await waitUntil { router.path.isEmpty }
        XCTAssertTrue(router.path.isEmpty)
    }

    func testPopToSpecificRoute() async {
        let router = KVAppRouter()
        router.setPath([TestRoute.screen("a"), .screen("b"), .screen("c")])
        await waitUntil { router.path.count == 3 }

        router.popTo(TestRoute.screen("a"))
        await waitUntil { router.path.count == 1 }
        XCTAssertEqual(router.path, [.screen("a")])
    }

    func testPopCount() async {
        let router = KVAppRouter()
        router.setPath([TestRoute.screen("a"), .screen("b"), .screen("c")])
        await waitUntil { router.path.count == 3 }

        router.pop(count: 2)
        await waitUntil { router.path.count == 1 }
        XCTAssertEqual(router.path, [.screen("a")])
    }

    func testReplaceTop() async {
        let router = KVAppRouter()
        router.push(TestRoute.screen("a"))
        await waitUntil { router.path.count == 1 }

        router.replaceTop(with: TestRoute.screen("b"))
        await waitUntil { router.path == [.screen("b")] }
        XCTAssertEqual(router.path, [.screen("b")])
    }

    // MARK: - Pop to Specific Screen (tag / view type)

    private struct ScreenA: View { var body: some View { Text("A") } }
    private struct ScreenB: View { var body: some View { Text("B") } }

    func testPopToTagTargetsDynamicView() async {
        let router = KVAppRouter()
        router.push(TestRoute.screen("home"))
        router.pushView(tag: "detail") { ScreenA() }
        router.pushView { ScreenB() }
        router.pushView { ScreenB() }
        await waitUntil { router.path.count == 4 }

        router.popTo(tag: "detail")
        await waitUntil { router.path.count == 2 }
        XCTAssertEqual(router.path.count, 2, "Should pop back to the tagged screen")
        XCTAssertEqual(router.path.first, .screen("home"))
    }

    /// Tags belong to `pushView`. In 2.x `popTo(tag:)` also matched a typed
    /// route whose id equalled the tag; 3.0 drops that overlap — a typed route
    /// is a value, so `popTo(_:)` addresses it directly and needs no tag.
    func testPopToTagIgnoresTypedRoutes() async {
        let router = KVAppRouter()
        router.push(TestRoute.screen("home"))
        router.pushView { ScreenA() }
        router.pushView { ScreenB() }
        await waitUntil { router.path.count == 3 }

        router.popTo(tag: "home")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(router.path.count, 3, "A typed route must not answer to a tag")

        router.popTo(TestRoute.screen("home"))
        await waitUntil { router.path.count == 1 }
        XCTAssertEqual(router.path, [.screen("home")])
    }

    func testPopToTagNotFoundDoesNothing() async {
        let router = KVAppRouter()
        router.pushView(tag: "a") { ScreenA() }
        await waitUntil { router.path.count == 1 }

        router.popTo(tag: "missing")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(router.path.count, 1)
    }

    func testPopToViewType() async {
        let router = KVAppRouter()
        router.pushView { ScreenA() }
        router.pushView { ScreenB() }
        router.pushView { ScreenB() }
        await waitUntil { router.path.count == 3 }

        router.popTo(ScreenA.self)
        await waitUntil { router.path.count == 1 }
        XCTAssertEqual(router.path.count, 1, "Should pop back to the ScreenA instance")
    }

    func testPopToViewTypePicksNearestMatch() async {
        let router = KVAppRouter()
        router.pushView { ScreenA() }
        router.pushView { ScreenB() }
        router.pushView { ScreenA() }
        router.pushView { ScreenB() }
        await waitUntil { router.path.count == 4 }

        router.popTo(ScreenA.self)
        await waitUntil { router.path.count == 3 }
        XCTAssertEqual(router.path.count, 3, "Should pop to the ScreenA nearest to the top")
    }

    func testPopToViewTypeFromMatchingScreenGoesToPreviousInstance() async {
        let router = KVAppRouter()
        router.pushView { ScreenA() }
        router.pushView { ScreenA() }
        await waitUntil { router.path.count == 2 }

        // Standing on a ScreenA: the top is excluded, so this pops back
        // to the previous ScreenA instead of matching itself (no-op).
        router.popTo(ScreenA.self)
        await waitUntil { router.path.count == 1 }
        XCTAssertEqual(router.path.count, 1)
    }

    /// `pushView` screens hold their view as a closure in memory, so they must
    /// never be able to claim they survive persistence.
    func testDynamicViewRoutesAreNotRestorable() {
        XCTAssertFalse(KVDynamicViewRoute.self is any KVRestorableRoute.Type)
        XCTAssertTrue(TestRestorableRoute.self is any KVRestorableRoute.Type)
    }

    // MARK: - Operation Ordering

    /// Middleware that is slow only for the first route — without the FIFO
    /// operation queue, the second push would land before the first.
    private struct SlowFirstMiddleware: KVRouteMiddleware {
        func willNavigate(from: (any KVRoute)?, to: any KVRoute) async -> (any KVRoute)? {
            if (to as? TestRoute) == .screen("slow") {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            return to
        }
    }

    func testConsecutivePushesKeepOrderWithAsyncMiddleware() async {
        let router = KVAppRouter(middlewares: [SlowFirstMiddleware()])
        router.push(TestRoute.screen("slow"))
        router.push(TestRoute.screen("fast"))
        await waitUntil { router.path.count == 2 }
        XCTAssertEqual(router.path, [.screen("slow"), .screen("fast")])
    }

    // MARK: - Middleware

    private struct RedirectMiddleware: KVRouteMiddleware {
        func willNavigate(from: (any KVRoute)?, to: any KVRoute) async -> (any KVRoute)? {
            if (to as? TestRoute) == .screen("blocked") { return TestRoute.screen("login") }
            return to
        }
    }

    private struct DenyAllMiddleware: KVRouteMiddleware {
        func willNavigate(from: (any KVRoute)?, to: any KVRoute) async -> (any KVRoute)? { nil }
        func willPop(from: (any KVRoute)?, to: (any KVRoute)?) async -> Bool { false }
    }

    func testMiddlewareRedirectsRoute() async {
        let router = KVAppRouter(middlewares: [RedirectMiddleware()])
        router.push(TestRoute.screen("blocked"))
        await waitUntil { !router.path.isEmpty }
        XCTAssertEqual(router.path, [.screen("login")])
    }

    func testMiddlewareCancelsPush() async {
        let router = KVAppRouter(middlewares: [DenyAllMiddleware()])
        router.push(TestRoute.screen("anything"))
        // Give the scheduled task time to run, then confirm nothing was pushed.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(router.path.isEmpty)
    }
}
