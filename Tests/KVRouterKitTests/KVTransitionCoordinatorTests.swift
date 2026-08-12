import XCTest
@testable import KVRouterKit

@MainActor
final class KVTransitionCoordinatorTests: XCTestCase {
    func testSystemTransitionDoesNotCreatePendingTransaction() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .slide())
        var mutated = false

        await coordinator.perform(pushRequest(transition: .system)) {
            mutated = true
        }

        XCTAssertTrue(mutated)
        XCTAssertNil(coordinator.pendingTransaction)
    }

    func testCustomTransitionWithoutBridgeFallsBackWithoutWaiting() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .slide())
        var mutated = false

        await coordinator.perform(pushRequest(transition: .slide())) {
            mutated = true
        }

        XCTAssertTrue(mutated)
        XCTAssertNil(coordinator.pendingTransaction)
    }

    func testCustomTransitionWaitsForUIKitCompletion() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .slide())
        coordinator.isBridgeAttached = true
        var mutated = false
        var finished = false

        let task = Task { @MainActor in
            await coordinator.perform(pushRequest(transition: .slide())) {
                mutated = true
            }
            finished = true
        }

        await waitUntil { coordinator.pendingTransaction != nil }
        XCTAssertTrue(mutated)
        XCTAssertFalse(finished)

        coordinator.completePendingTransition(cancelled: false)
        await task.value

        XCTAssertTrue(finished)
        XCTAssertNil(coordinator.pendingTransaction)
    }

    func testCompletionIsIdempotent() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .fade)
        coordinator.isBridgeAttached = true
        var completionCount = 0

        let task = Task { @MainActor in
            await coordinator.perform(pushRequest(transition: .fade)) {}
            completionCount += 1
        }

        await waitUntil { coordinator.pendingTransaction != nil }
        coordinator.completePendingTransition(cancelled: false)
        coordinator.completePendingTransition(cancelled: false)
        await task.value

        XCTAssertEqual(completionCount, 1)
    }

    func testNativeZoomEntryKeepsNativeBackendForPop() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Native navigation zoom requires iOS 18 or newer")
        }

        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.hasSource = { $0 == AnyHashable("card") }
        let entry = KVNavigationEntry(route: .appFeature("detail"))

        await coordinator.perform(
            KVTransitionRequest(
                operation: .push,
                from: nil,
                to: entry,
                transitionOverride: .zoom(sourceID: "card")
            )
        ) {}

        coordinator.hasSource = { _ in false }
        let pop = KVTransitionRequest(
            operation: .pop,
            from: entry,
            to: nil,
            transitionOverride: .zoom(sourceID: "card")
        )

        XCTAssertTrue(coordinator.usesNativeZoom(for: entry))
        XCTAssertEqual(
            coordinator.resolve(pop, supportsNativeZoom: true).backend,
            .nativeZoom
        )
    }

    func testLegacyZoomPopDefersMissingSourceFallbackToAnimator() {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.hasSource = { _ in false }
        let entry = KVNavigationEntry(route: .appFeature("detail"))
        let request = KVTransitionRequest(
            operation: .pop,
            from: entry,
            to: nil,
            transitionOverride: .zoom(sourceID: "card")
        )

        let resolved = coordinator.resolve(
            request,
            supportsNativeZoom: false
        )

        XCTAssertEqual(resolved.backend, .custom)
        XCTAssertEqual(resolved.transition.debugKind, .zoom)
    }

    func testExternalPopUsesOutgoingControllerCustomTransition() {
        let router = KVAppRouter()
        let coordinator = KVTransitionCoordinator(defaultTransition: .depth)
        coordinator.router = router
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        navigationController.setViewControllers(
            [root, detail],
            animated: false
        )
        router.navigationEntries = [
            KVNavigationEntry(route: .appFeature("detail"))
        ]

        coordinator.synchronizeControllerMetadata(in: navigationController)

        XCTAssertTrue(
            coordinator.animator(
                for: .pop,
                from: detail,
                to: root
            ) != nil
        )
        XCTAssertNil(coordinator.pendingTransaction)
    }

    func testExternalPopDoesNotOverrideSystemTransition() {
        let router = KVAppRouter()
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.router = router
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        navigationController.setViewControllers(
            [root, detail],
            animated: false
        )
        router.navigationEntries = [
            KVNavigationEntry(route: .appFeature("detail"))
        ]
        coordinator.synchronizeControllerMetadata(in: navigationController)

        XCTAssertNil(
            coordinator.animator(
                for: .pop,
                from: detail,
                to: root
            )
        )
    }

    func testControllerMetadataIsRemovedWithDestinationController() {
        let router = KVAppRouter()
        let coordinator = KVTransitionCoordinator(defaultTransition: .depth)
        coordinator.router = router
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        navigationController.setViewControllers(
            [root, detail],
            animated: false
        )
        router.navigationEntries = [
            KVNavigationEntry(route: .appFeature("detail"))
        ]
        coordinator.synchronizeControllerMetadata(in: navigationController)

        navigationController.setViewControllers([root], animated: false)
        router.navigationEntries = []
        coordinator.synchronizeControllerMetadata(in: navigationController)

        XCTAssertNil(
            coordinator.animator(
                for: .pop,
                from: detail,
                to: root
            )
        )
    }

    func testPathCleanupKeepsOutgoingMetadataUntilUIKitPopFinishes() {
        let router = KVAppRouter()
        let coordinator = KVTransitionCoordinator(defaultTransition: .depth)
        coordinator.router = router
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        navigationController.setViewControllers(
            [root, detail],
            animated: false
        )
        router.navigationEntries = [
            KVNavigationEntry(route: .appFeature("detail"))
        ]
        coordinator.synchronizeControllerMetadata(in: navigationController)

        coordinator.retainEntryMetadata(for: [])

        XCTAssertNotNil(
            coordinator.animator(
                for: .pop,
                from: detail,
                to: root
            )
        )
    }

    func testExternalPopDoesNotOverrideNativeZoom() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Native navigation zoom requires iOS 18 or newer")
        }

        let router = KVAppRouter()
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.router = router
        coordinator.hasSource = { $0 == AnyHashable("card") }
        let entry = KVNavigationEntry(route: .appFeature("detail"))

        await coordinator.perform(
            KVTransitionRequest(
                operation: .push,
                from: nil,
                to: entry,
                transitionOverride: .zoom(sourceID: "card")
            )
        ) {
            router.navigationEntries = [entry]
        }

        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        navigationController.setViewControllers(
            [root, detail],
            animated: false
        )
        coordinator.synchronizeControllerMetadata(in: navigationController)

        XCTAssertNil(
            coordinator.animator(
                for: .pop,
                from: detail,
                to: root
            )
        )
    }

    private func pushRequest(
        transition: KVNavigationTransition
    ) -> KVTransitionRequest {
        KVTransitionRequest(
            operation: .push,
            from: nil,
            to: KVNavigationEntry(route: .appFeature("detail")),
            transitionOverride: transition
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }
}
