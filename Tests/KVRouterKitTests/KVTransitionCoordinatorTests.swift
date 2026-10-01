import XCTest
import KVRouterCore
import SwiftUI
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
        let entry = KVNavigationEntry(route: TestRoute.screen("detail"))

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
            coordinator.nativeZoomSourceID(for: entry),
            AnyHashable("card")
        )
        XCTAssertEqual(
            coordinator.resolve(pop, supportsNativeZoom: true).backend,
            .nativeZoom
        )
    }

    func testLegacyZoomPopDefersMissingSourceFallbackToAnimator() {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.hasSource = { _ in false }
        let entry = KVNavigationEntry(route: TestRoute.screen("detail"))
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
            KVNavigationEntry(route: TestRoute.screen("detail"))
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
            KVNavigationEntry(route: TestRoute.screen("detail"))
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
            KVNavigationEntry(route: TestRoute.screen("detail"))
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
            KVNavigationEntry(route: TestRoute.screen("detail"))
        ]
        coordinator.synchronizeControllerMetadata(in: navigationController)

        // The router's path is cleaned up while UIKit is still popping. Nothing
        // about that may invalidate the outgoing controller's metadata, or the
        // pop loses its animator half-way through.
        router.navigationEntries = []

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
        let entry = KVNavigationEntry(route: TestRoute.screen("detail"))

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

    // MARK: - Native zoom metadata lifetime

    /// The reported bug: swipe-to-dismiss left the zoom source hidden while a
    /// button dismiss was fine. The path changes when an interactive dismissal
    /// *commits*, before its animation ends, and `usesNativeZoom(for:)` is what
    /// keeps `.navigationTransition(.zoom:)` on the destination. Pruning on the
    /// path change dropped it mid-dismissal; it must survive until the
    /// transition reports finished.
    func testNativeZoomMetadataSurvivesThePathChangeUntilTheTransitionFinishes() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Native navigation zoom requires iOS 18 or newer")
        }
        let router = KVAppRouter()
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.router = router
        coordinator.hasSource = { _ in true }
        let navigationController = UINavigationController(
            rootViewController: UIViewController()
        )
        coordinator.attach(to: navigationController)

        let entry = KVNavigationEntry(route: TestRoute.screen("detail"))
        await coordinator.perform(
            KVTransitionRequest(
                operation: .push,
                from: nil,
                to: entry,
                transitionOverride: .zoom(sourceID: "card")
            )
        ) { router.navigationEntries = [entry] }
        XCTAssertTrue(coordinator.usesNativeZoom(for: entry))

        // The dismissal commits: the entry leaves the stack while its animation
        // is still running.
        router.navigationEntries = []

        XCTAssertTrue(
            coordinator.usesNativeZoom(for: entry),
            "Zoom metadata must outlive the path change, or the destination loses .navigationTransition(.zoom:) mid-dismissal"
        )

        // UIKit reports the transition finished; now it can go.
        coordinator.navigationControllerDidShow(navigationController)

        XCTAssertFalse(coordinator.usesNativeZoom(for: entry))
        XCTAssertEqual(coordinator.retainedNativeZoomEntryCount(), 0)
    }

    /// A pop changes the path before its animation runs, and the outgoing screen re-renders
    /// mid-transition. Dropping a `pushView` builder on the path change rebuilt that screen as
    /// an empty view: a black first frame, and an anchored zoom's destination view gone, so the
    /// pop fell back to `.scaleAndFade`. The builder must survive until the transition finishes.
    func testPushViewBuilderSurvivesThePopUntilTheTransitionFinishes() async {
        let router = KVAppRouter()
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.router = router
        let navigationController = UINavigationController(rootViewController: UIViewController())
        coordinator.attach(to: navigationController)

        router.pushView { Text("Viewer") }
        await waitUntil { router.navigationEntries.count == 1 }
        guard let dynamic = router.navigationEntries.first?.route.unwrap(KVDynamicViewRoute.self) else {
            return XCTFail("pushView should record a dynamic route")
        }
        XCTAssertNotNil(router.dynamicView(for: dynamic))

        // The pop commits: the entry leaves the path while its animation is still running.
        router.navigationEntries = []
        XCTAssertNotNil(router.dynamicView(for: dynamic), "The outgoing screen still renders during the pop")

        // UIKit reports the transition finished; now it can go.
        coordinator.navigationControllerDidShow(navigationController)
        XCTAssertNil(router.dynamicView(for: dynamic))
    }

    /// A native zoom can leave `matchedTransitionSource` holding SwiftUI's
    /// private hidden flag after the pop. The destination must keep the source
    /// identity it started with until UIKit finishes, then the returned source
    /// gets a new identity so that stale flag cannot attach to it.
    func testCompletedNativeZoomPopRotatesTheSourceIdentity() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Native navigation zoom requires iOS 18 or newer")
        }
        let router = KVAppRouter()
        let registry = KVTransitionSourceRegistry()
        registry.update(
            id: "card",
            frame: CGRect(x: 0, y: 0, width: 120, height: 90),
            view: nil
        )
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.router = router
        coordinator.sourceRegistry = registry
        let navigationController = UINavigationController(
            rootViewController: UIViewController()
        )
        let originalSourceID = registry.nativeSourceID(for: "card")
        let entry = KVNavigationEntry(route: TestRoute.screen("detail"))

        await coordinator.perform(
            KVTransitionRequest(
                operation: .push,
                from: nil,
                to: entry,
                transitionOverride: .zoom(sourceID: "card")
            )
        ) { router.navigationEntries = [entry] }

        XCTAssertEqual(
            coordinator.nativeZoomSourceID(for: entry),
            originalSourceID
        )

        // Committing the path change must not rotate the identity while the
        // destination is still animating toward it.
        router.navigationEntries = []
        XCTAssertEqual(
            registry.nativeSourceID(for: "card"),
            originalSourceID
        )

        coordinator.navigationControllerDidShow(navigationController)

        XCTAssertNil(coordinator.nativeZoomSourceID(for: entry))
        XCTAssertNotEqual(
            registry.nativeSourceID(for: "card"),
            originalSourceID
        )
    }

    // MARK: - Animation forcing

    /// `.system` is the reason animation forcing exists: UIKit owns the
    /// animation and SwiftUI sometimes hands it `animated: false`.
    func testSystemTransitionArmsAnimationForcing() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)

        await coordinator.perform(pushRequest(transition: .system)) {}

        XCTAssertTrue(
            coordinator.shouldForceNavigationAnimation(
                for: .push,
                from: nil,
                to: nil
            )
        )
    }

    /// The native-zoom **pop** must not be forced. SwiftUI drives the zoom
    /// dismissal itself and passes `animated: false` on purpose; forcing it made
    /// UIKit run a second, concurrent transition and SwiftUI never un-hid the
    /// `matchedTransitionSource`, so the source view stayed invisible after the
    /// dismiss while still holding its slot in the layout.
    ///
    /// The push keeps the forcing — see
    /// `testNativeZoomTransitionForcesUIKitAnimationWhenRequestedFalse`.
    func testNativeZoomPopDoesNotArmAnimationForcing() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Native navigation zoom requires iOS 18 or newer")
        }
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.hasSource = { _ in true }
        let entry = KVNavigationEntry(route: TestRoute.screen("detail"))

        await coordinator.perform(
            KVTransitionRequest(
                operation: .push,
                from: nil,
                to: entry,
                transitionOverride: .zoom(sourceID: "card")
            )
        ) {}
        // Consume the push intent so the pop is measured on its own.
        _ = coordinator.shouldForceNavigationAnimation(
            for: .push,
            from: nil,
            to: nil
        )

        await coordinator.perform(
            KVTransitionRequest(
                operation: .pop,
                from: entry,
                to: nil,
                transitionOverride: .zoom(sourceID: "card")
            )
        ) {}

        XCTAssertFalse(
            coordinator.shouldForceNavigationAnimation(
                for: .pop,
                from: nil,
                to: nil
            ),
            "A native-zoom pop must leave the UIKit animation flag alone"
        )
    }

    private func pushRequest(
        transition: KVNavigationTransition
    ) -> KVTransitionRequest {
        KVTransitionRequest(
            operation: .push,
            from: nil,
            to: KVNavigationEntry(route: TestRoute.screen("detail")),
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
