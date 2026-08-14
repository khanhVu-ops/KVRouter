import XCTest
import KVRouterCore
@testable import KVRouterKit

private final class RecordingDriver: KVTransitionDriving {
    var requests: [KVTransitionRequest] = []
    var silentEditCount = 0

    func perform(
        _ request: KVTransitionRequest,
        mutation: @escaping @MainActor () -> Void
    ) async {
        requests.append(request)
        mutation()
    }

    func performSilently(_ edit: @MainActor () -> Void) {
        silentEditCount += 1
        edit()
    }
}

@MainActor
private final class SuspendedDriver: KVTransitionDriving {
    private(set) var requests: [KVTransitionRequest] = []
    private(set) var mutationCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func perform(
        _ request: KVTransitionRequest,
        mutation: @escaping @MainActor () -> Void
    ) async {
        requests.append(request)
        mutation()
        mutationCount += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
final class KVNavigationEntryTests: XCTestCase {
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testDuplicateRoutesReceiveDifferentEntryIDs() async {
        let router = KVAppRouter()
        router.push(TestRoute.screen("detail"), transition: .fade)
        router.push(TestRoute.screen("detail"), transition: .depth)
        await waitUntil { router.navigationEntries.count == 2 }

        XCTAssertNotEqual(router.navigationEntries[0].id, router.navigationEntries[1].id)
        XCTAssertEqual(router.transitionOverride(for: router.navigationEntries[0])?.debugKind, .fade)
        XCTAssertEqual(router.transitionOverride(for: router.navigationEntries[1])?.debugKind, .depth)
    }

    // MARK: - Route-level default transitions

    /// The router holds the registry weakly — in an app the view tree owns it —
    /// so these tests park it here for the lifetime of the test case.
    private var retainedRegistry: KVRouteRegistry?

    private func routerWithRouteTransition(
        _ transition: KVNavigationTransition
    ) -> KVAppRouter {
        let registry = KVRouteRegistry()
        registry.registerTransition(TestRoute.self) { _ in transition }
        retainedRegistry = registry
        let router = KVAppRouter()
        router.routeRegistry = registry
        return router
    }

    func testPushWithoutTransitionUsesTheRouteDefault() async {
        let router = routerWithRouteTransition(.fade)

        router.push(TestRoute.screen("detail"))
        await waitUntil { router.navigationEntries.count == 1 }

        XCTAssertEqual(
            router.transitionOverride(for: router.navigationEntries[0])?.debugKind,
            .fade
        )
    }

    func testCallSiteTransitionBeatsTheRouteDefault() async {
        let router = routerWithRouteTransition(.fade)

        router.push(TestRoute.screen("detail"), transition: .depth)
        await waitUntil { router.navigationEntries.count == 1 }

        XCTAssertEqual(
            router.transitionOverride(for: router.navigationEntries[0])?.debugKind,
            .depth
        )
    }

    /// A route type that declared nothing must still fall through to the host's
    /// `defaultTransition`, which `nil` is how the host reads.
    func testUndeclaredRouteTypeStillResolvesToNil() async {
        let registry = KVRouteRegistry()
        registry.registerTransition(OtherTestRoute.self) { _ in .fade }
        retainedRegistry = registry
        let router = KVAppRouter()
        router.routeRegistry = registry

        router.push(TestRoute.screen("detail"))
        await waitUntil { router.navigationEntries.count == 1 }

        XCTAssertNil(router.transitionOverride(for: router.navigationEntries[0]))
    }

    /// Entries created by a direct path assignment never went through `push`, so
    /// their transition can only come from the registry.
    func testPathAssignmentPicksUpTheRouteDefault() {
        let router = routerWithRouteTransition(.depth)

        router.path = [.screen("a"), .screen("b")]

        XCTAssertEqual(
            router.transitionOverride(for: router.navigationEntries[1])?.debugKind,
            .depth
        )
    }

    /// The pop side reads the same funnel, so going back plays the route's own
    /// transition in reverse rather than the host default.
    func testPopCarriesTheRouteDefault() async {
        let router = routerWithRouteTransition(.flip3D())
        let driver = RecordingDriver()
        router.transitionDriver = driver

        router.push(TestRoute.screen("detail"))
        await waitUntil { router.path.count == 1 }
        router.pop()
        await waitUntil { router.path.isEmpty }

        XCTAssertEqual(driver.requests.map(\.operation), [.push, .pop])
        XCTAssertEqual(driver.requests.last?.transitionOverride?.debugKind, .flip3D)
    }

    /// Nothing keeps the registry alive but the view tree; a torn-down host must
    /// not leave the router reading a dead one.
    func testRouterHoldsTheRegistryWeakly() {
        let router = KVAppRouter()
        do {
            let registry = KVRouteRegistry()
            registry.registerTransition(TestRoute.self) { _ in .fade }
            router.routeRegistry = registry
            XCTAssertNotNil(router.routeRegistry)
        }

        XCTAssertNil(router.routeRegistry)
    }

    func testDirectPathAssignmentReusesCommonPrefix() {
        let router = KVAppRouter()
        router.path = [.screen("a"), .screen("b")]
        let originalA = router.navigationEntries[0].id

        router.path = [.screen("a"), .screen("c")]

        XCTAssertEqual(router.navigationEntries[0].id, originalA)
        XCTAssertEqual(router.navigationEntries.map(\.route), [.screen("a"), .screen("c")])
        XCTAssertNil(router.transitionOverride(for: router.navigationEntries[1]))
    }

    func testSystemPopRemovesEntryMetadata() async {
        let router = KVAppRouter()
        router.push(TestRoute.screen("a"), transition: .fade)
        router.push(TestRoute.screen("b"), transition: .depth)
        await waitUntil { router.navigationEntries.count == 2 }
        let removed = router.navigationEntries[1]

        router.navigationEntries = [router.navigationEntries[0]]

        XCTAssertNil(router.transitionOverride(for: removed))
        XCTAssertEqual(router.path, [.screen("a")])
    }

    func testRouterSendsPushAndPopThroughDriver() async {
        let router = KVAppRouter()
        let driver = RecordingDriver()
        router.transitionDriver = driver

        router.push(TestRoute.screen("detail"), transition: .depth)
        await waitUntil { router.path.count == 1 }
        router.pop()
        await waitUntil { router.path.isEmpty }

        XCTAssertEqual(driver.requests.map(\.operation), [.push, .pop])
        XCTAssertEqual(driver.requests.first?.transitionOverride?.debugKind, .depth)
    }

    func testRouterWaitsForTransitionCompletionAndMutatesOnce() async {
        let router = KVAppRouter()
        router.path = [.screen("detail")]
        let driver = SuspendedDriver()
        router.transitionDriver = driver

        router.pop()
        await waitUntil { driver.mutationCount == 1 }
        router.push(TestRoute.screen("next"), transition: .fade)
        await Task.yield()

        XCTAssertTrue(router.path.isEmpty)
        XCTAssertEqual(driver.requests.count, 1)
        XCTAssertEqual(driver.mutationCount, 1)

        driver.resume()
        await waitUntil { driver.requests.count == 2 }

        XCTAssertEqual(driver.mutationCount, 2)
        driver.resume()
    }

    /// A replace cannot be animated, so it does not go through the driver.
    ///
    /// The custom animator hangs off `UINavigationControllerDelegate`, and
    /// SwiftUI does not hand UIKit a same-depth stack mutation for a changed top
    /// entry, so the delegate is never asked. 2.x accepted a `transition:` here
    /// and silently ignored it; 3.0 does not offer one.
    func testReplaceTopBypassesCustomTransitionDriver() async {
        let router = KVAppRouter()
        router.path = [.screen("a"), .screen("b")]
        let driver = RecordingDriver()
        router.transitionDriver = driver

        router.replaceTop(with: TestRoute.screen("c"))
        await waitUntil { router.path.last == .screen("c") }

        XCTAssertTrue(driver.requests.isEmpty)
        XCTAssertEqual(router.path, [.screen("a"), .screen("c")])
    }

    // MARK: - Animated replace

    /// The animated replace is a push plus a drop. Exactly one animated request
    /// may reach the driver: the reported symptom was the transition playing
    /// twice, because the drop picked up an animator of its own.
    func testAnimatedReplaceAnimatesOnceAndDropsSilently() async {
        let router = KVAppRouter()
        router.path = [.screen("a"), .screen("b")]
        let driver = RecordingDriver()
        router.transitionDriver = driver

        router.replaceTop(with: TestRoute.screen("c"), transition: .flip3D())
        await waitUntil { router.path == [.screen("a"), .screen("c")] }

        XCTAssertEqual(driver.requests.count, 1, "The drop must not be animated")
        XCTAssertEqual(driver.requests.first?.operation, .push)
        XCTAssertEqual(driver.requests.first?.transitionOverride?.debugKind, .flip3D)
        XCTAssertEqual(driver.silentEditCount, 1)
        XCTAssertEqual(router.stackDepth, 2)
    }

    /// Going back from the replacing screen should look like going back from what
    /// it replaced — not like the replace animation running in reverse.
    func testAnimatedReplaceInheritsThePopTransitionItReplaced() async {
        let router = KVAppRouter()
        router.push(TestRoute.screen("a"), transition: .sharedAxis())
        await waitUntil { router.stackDepth == 1 }
        let replaced = router.navigationEntries[0]
        XCTAssertEqual(router.transitionOverride(for: replaced)?.debugKind, .sharedAxis)

        router.replaceTop(with: TestRoute.screen("b"), transition: .flip3D())
        await waitUntil { router.path == [.screen("b")] }

        let replacement = router.navigationEntries[0]
        XCTAssertEqual(
            router.transitionOverride(for: replacement)?.debugKind,
            .sharedAxis,
            "The replacement must pop with the transition of the screen it replaced"
        )
    }

    /// Replacing the only screen has nothing to inherit from, so the transition
    /// is genuinely that screen's own.
    func testAnimatedReplaceOnEmptyStackKeepsItsOwnTransition() async {
        let router = KVAppRouter()

        router.replaceTop(with: TestRoute.screen("a"), transition: .flip3D())
        await waitUntil { router.stackDepth == 1 }

        XCTAssertEqual(
            router.transitionOverride(for: router.navigationEntries[0])?.debugKind,
            .flip3D
        )
    }

    /// A bulk pop still bypasses the driver: only single-screen changes have a
    /// UIKit operation to animate against.
    func testBulkPopBypassesCustomTransitionDriver() async {
        let router = KVAppRouter()
        router.path = [.screen("a"), .screen("b"), .screen("c")]
        let driver = RecordingDriver()
        router.transitionDriver = driver

        router.popToRoot()
        await waitUntil { router.path.isEmpty }

        XCTAssertTrue(driver.requests.isEmpty)
    }
}
