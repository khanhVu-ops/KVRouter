//
//  KVRouterRegressionTests.swift
//  KVRouterKit
//
//  One test per defect fixed in the state-machine pass. Each fails on the
//  pre-fix implementation.
//

import XCTest
import KVRouterCore
@testable import KVRouterKit

@MainActor
private final class RecordingPopMiddleware: KVRouteMiddleware {
    private(set) var poppedNames: [String] = []

    func willNavigate(from: (any KVRoute)?, to: any KVRoute) async -> (any KVRoute)? {
        to
    }

    func willPop(from: (any KVRoute)?, to: (any KVRoute)?) async -> Bool {
        if let name = (from as? TestRoute)?.name {
            poppedNames.append(name)
        }
        return true
    }
}

/// Never answers, standing in for a middleware awaiting something that never
/// arrives (an un-timed-out network call, a continuation nobody resumes).
private struct HangingMiddleware: KVRouteMiddleware {
    func willNavigate(from: (any KVRoute)?, to: any KVRoute) async -> (any KVRoute)? {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        return to
    }
}

@MainActor
final class KVRouterRegressionTests: XCTestCase {

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Router-removed bookkeeping

    /// A back gesture claims the top entry, then the stack moves under it so the
    /// commit fails. With a single `isRouterControlledPop` flag the claim stayed
    /// `true` and the *next* system pop silently skipped `willPop` — a
    /// "warn about unsaved changes" middleware would never fire.
    func testStaleInteractivePopClaimDoesNotSwallowLaterMiddleware() async {
        let middleware = RecordingPopMiddleware()
        let router = KVAppRouter(middlewares: [middleware])
        router.path = [.screen("a"), .screen("b")]
        await router.settle()

        let request = router.interactivePopRequest()
        XCTAssertNotNil(request)
        router.prepareInteractivePop(request!)

        // The stack moves while the gesture is in flight.
        router.path = [.screen("a"), .screen("b"), .screen("c")]
        XCTAssertFalse(
            router.commitInteractivePop(request!),
            "The commit must fail once the claimed entry is no longer on top"
        )

        // A genuine system pop afterwards still has to notify middleware.
        router.path = [.screen("a"), .screen("b")]
        await router.settle()

        XCTAssertEqual(middleware.poppedNames, ["c"])
    }

    func testRouterDrivenPopRunsMiddlewareExactlyOnce() async {
        let middleware = RecordingPopMiddleware()
        let router = KVAppRouter(middlewares: [middleware])
        router.path = [.screen("a"), .screen("b")]
        await router.settle()

        router.pop()
        await router.settle()

        XCTAssertEqual(middleware.poppedNames, ["b"])
    }

    /// A system pop of several screens at once used to spawn one detached Task
    /// per screen, so their middleware could interleave with each other and with
    /// queued operations. They now run in order, on the queue.
    func testSystemPopOfSeveralScreensRunsMiddlewareTopDown() async {
        let middleware = RecordingPopMiddleware()
        let router = KVAppRouter(middlewares: [middleware])
        router.path = [.screen("a"), .screen("b"), .screen("c")]
        await router.settle()

        router.path = [.screen("a")]
        await router.settle()

        XCTAssertEqual(middleware.poppedNames, ["c", "b"])
    }

    // MARK: - Middleware timeout

    /// The transition path had a watchdog; the middleware path had none, so one
    /// `await` that never returned wedged the queue for the rest of the process.
    /// If this regresses, `settle()` never returns and the test times out.
    func testHangingMiddlewareDoesNotWedgeTheQueue() async {
        let router = KVAppRouter(middlewares: [HangingMiddleware()])
        router.middlewareTimeout = 0.05
        router.assertsOnMiddlewareTimeout = false

        router.push(TestRoute.screen("never"))
        await router.settle()

        XCTAssertTrue(
            router.path.isEmpty,
            "A chain that never answers must be read as denying the navigation"
        )
    }

    func testQueueKeepsWorkingAfterAMiddlewareTimeout() async {
        let router = KVAppRouter(middlewares: [HangingMiddleware()])
        router.middlewareTimeout = 0.05
        router.assertsOnMiddlewareTimeout = false

        router.push(TestRoute.screen("never"))
        await router.settle()

        // Same router, second operation: the queue must not be poisoned.
        router.push(TestRoute.screen("also-never"))
        await router.settle()

        XCTAssertTrue(router.path.isEmpty)
    }

    func testZeroTimeoutSkipsTheRaceEntirely() async {
        let middleware = RecordingPopMiddleware()
        let router = KVAppRouter(middlewares: [middleware])
        router.middlewareTimeout = 0

        router.push(TestRoute.screen("a"))
        await router.settle()

        XCTAssertEqual(router.path, [.screen("a")])
    }

    // MARK: - Placeholder router

    /// Reading `@Environment(\.router)` without a host used to hand back a real,
    /// unhosted router: navigation vanished with no crash and no log.
    func testPlaceholderRouterReportsInsteadOfSwallowing() {
        let router = KVNullRouter()
        XCTAssertEqual(router.stackDepth, 0)
        XCTAssertNil(router.topRoute)
        // The commands themselves assert in debug, which is the point; only the
        // inert state is safe to observe here.
    }

    /// The `KVRouting`-level counterpart, for a dependency graph that needs a
    /// placeholder before the composition root has built a router. Same trade as
    /// above: the commands assert, so only the inert state is observable.
    func testUnhostedRouterExposesAnEmptyStackThroughThePort() {
        let router: any KVRouting = KVUnhostedRouter()

        XCTAssertEqual(router.stackDepth, 0)
        XCTAssertNil(router.topRoute)
        XCTAssertTrue(router.routes.isEmpty)
    }

    /// 3.2.0 shipped the placeholder with an initializer that inherited the
    /// class's `@MainActor`, which made it unusable in the one place it exists
    /// for. `NonisolatedDependencyGraph` below is the guard: it only compiles
    /// while `init` stays `nonisolated`, and no runtime assertion can catch this.
    func testUnhostedRouterIsReachableFromANonisolatedDependencyGraph() {
        XCTAssertEqual(NonisolatedDependencyGraph.router.stackDepth, 0)
    }
}

/// A dependency key's default value is a `nonisolated static`. Constructing the
/// placeholder here is the whole point of it, so this declaration doubles as a
/// compile-time regression test.
private enum NonisolatedDependencyGraph {
    static let router: any KVRouting = KVUnhostedRouter()
}
