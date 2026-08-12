import UIKit
import SwiftUI
import XCTest
import KVRouterCore
@testable import KVRouterKit

@MainActor
final class KVNavigationControllerBridgeTests: XCTestCase {
    func testAttachIsIdempotentAndDetachRestoresOriginalDelegate() {
        let coordinator = KVTransitionCoordinator(defaultTransition: .slide())
        let navigationController = UINavigationController()
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original

        coordinator.attach(to: navigationController)
        let firstProxy = navigationController.delegate
        coordinator.attach(to: navigationController)

        XCTAssertTrue(coordinator.isBridgeAttached)
        XCTAssertTrue(navigationController.delegate === firstProxy)
        XCTAssertFalse(navigationController.delegate === original)

        coordinator.detach()

        XCTAssertFalse(coordinator.isBridgeAttached)
        XCTAssertTrue(navigationController.delegate === original)
    }

    func testProxyForwardsDidShowToOriginalDelegate() {
        let coordinator = KVTransitionCoordinator(defaultTransition: .slide())
        let navigationController = UINavigationController()
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        coordinator.attach(to: navigationController)
        let shown = UIViewController()

        navigationController.delegate?.navigationController?(
            navigationController,
            didShow: shown,
            animated: true
        )

        XCTAssertEqual(original.didShowCount, 1)
    }

    func testProxyReturnsAnimatorOnlyForMatchingPendingOperation() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .depth)
        let navigationController = UINavigationController()
        coordinator.attach(to: navigationController)
        let from = UIViewController()
        let to = UIViewController()

        let task = Task { @MainActor in
            await coordinator.perform(
                KVTransitionRequest(
                    operation: .push,
                    from: nil,
                    to: KVNavigationEntry(route: TestRoute.screen("detail")),
                    transitionOverride: .depth
                )
            ) {}
        }
        await waitUntil { coordinator.pendingTransaction != nil }

        let wrongOperation = navigationController.delegate?.navigationController?(
            navigationController,
            animationControllerFor: .pop,
            from: from,
            to: to
        )
        let matchingOperation = navigationController.delegate?.navigationController?(
            navigationController,
            animationControllerFor: .push,
            from: from,
            to: to
        )

        XCTAssertNil(wrongOperation)
        XCTAssertTrue(matchingOperation is KVViewControllerTransitionAnimator)

        coordinator.completePendingTransition(cancelled: false)
        await task.value
    }

    func testProxyReturnsAnimatorForSystemInitiatedCustomPop() {
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
        coordinator.attach(to: navigationController)

        let animator = navigationController.delegate?.navigationController?(
            navigationController,
            animationControllerFor: .pop,
            from: detail,
            to: root
        )

        XCTAssertTrue(animator is KVViewControllerTransitionAnimator)
        XCTAssertNil(coordinator.pendingTransaction)
    }

    func testAttachedCustomPushForcesUIKitAnimationWhenRequestedFalse() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        coordinator.attach(to: navigationController)
        original.reset()

        let task = Task { @MainActor in
            await coordinator.perform(
                KVTransitionRequest(
                    operation: .push,
                    from: nil,
                    to: KVNavigationEntry(route: TestRoute.screen("detail")),
                    transitionOverride: .depth
                )
            ) {
                navigationController.setViewControllers(
                    [root, detail],
                    animated: false
                )
            }
        }

        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(original.lastWillShowAnimated, true)
        XCTAssertTrue(
            coordinator.pendingTransaction?.animator
                is KVViewControllerTransitionAnimator
        )

        coordinator.completePendingTransition(cancelled: false)
        await task.value
        _ = window
    }

    func testAttachedCustomPopForcesUIKitAnimationWhenRequestedFalse() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        navigationController.setViewControllers(
            [root, detail],
            animated: false
        )
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        coordinator.attach(to: navigationController)
        original.reset()
        let entry = KVNavigationEntry(route: TestRoute.screen("detail"))

        let task = Task { @MainActor in
            await coordinator.perform(
                KVTransitionRequest(
                    operation: .pop,
                    from: entry,
                    to: nil,
                    transitionOverride: .depth
                )
            ) {
                navigationController.setViewControllers(
                    [root],
                    animated: false
                )
            }
        }

        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(original.lastWillShowAnimated, true)
        XCTAssertTrue(
            coordinator.pendingTransaction?.animator
                is KVViewControllerTransitionAnimator
        )

        coordinator.completePendingTransition(cancelled: false)
        await task.value
        _ = window
    }

    func testSystemInitiatedCustomPopForcesUIKitAnimation() async {
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
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        coordinator.attach(to: navigationController)
        original.reset()

        navigationController.setViewControllers(
            [root],
            animated: false
        )
        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(original.lastWillShowAnimated, true)
        XCTAssertNil(coordinator.pendingTransaction)
        _ = window
    }

    func testSystemInitiatedSystemPopForcesUIKitAnimation() async {
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
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        coordinator.attach(to: navigationController)
        original.reset()

        navigationController.setViewControllers(
            [root],
            animated: false
        )
        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(original.lastWillShowAnimated, true)
        XCTAssertNil(coordinator.pendingTransaction)
        _ = window
    }

    func testSystemInitiatedNativeZoomPopForcesUIKitAnimation() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Native navigation zoom requires iOS 18 or newer")
        }

        let router = KVAppRouter()
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.router = router
        coordinator.hasSource = { $0 == AnyHashable("card") }
        let root = UIViewController()
        let detail = UIViewController()
        let entry = KVNavigationEntry(route: TestRoute.screen("detail"))
        let navigationController = UINavigationController(
            rootViewController: root
        )
        navigationController.setViewControllers(
            [root, detail],
            animated: false
        )
        router.navigationEntries = [entry]

        await coordinator.perform(
            KVTransitionRequest(
                operation: .push,
                from: nil,
                to: entry,
                transitionOverride: .zoom(sourceID: "card")
            )
        ) {}

        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        coordinator.attach(to: navigationController)
        coordinator.navigationControllerDidShow(navigationController)
        original.reset()

        navigationController.setViewControllers(
            [root],
            animated: false
        )
        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(original.lastWillShowAnimated, true)
        XCTAssertNil(coordinator.pendingTransaction)
        _ = window
    }

    func testDirectCustomPopForcesUIKitAnimationWhenRequestedFalse() async {
        await assertCustomPopForcesAnimation { navigationController, _ in
            _ = navigationController.popViewController(animated: false)
        }
    }

    func testDirectCustomPopToPreviousForcesUIKitAnimationWhenRequestedFalse() async {
        await assertCustomPopForcesAnimation { navigationController, root in
            _ = navigationController.popToViewController(
                root,
                animated: false
            )
        }
    }

    func testDirectCustomPopToRootForcesUIKitAnimationWhenRequestedFalse() async {
        await assertCustomPopForcesAnimation { navigationController, _ in
            _ = navigationController.popToRootViewController(animated: false)
        }
    }

    func testDirectCustomPushForcesUIKitAnimationWhenRequestedFalse() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        coordinator.attach(to: navigationController)
        original.reset()

        let task = Task { @MainActor in
            await coordinator.perform(
                KVTransitionRequest(
                    operation: .push,
                    from: nil,
                    to: KVNavigationEntry(route: TestRoute.screen("detail")),
                    transitionOverride: .depth
                )
            ) {
                navigationController.pushViewController(
                    detail,
                    animated: false
                )
            }
        }

        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(original.lastWillShowAnimated, true)
        XCTAssertTrue(
            coordinator.pendingTransaction?.animator
                is KVViewControllerTransitionAnimator
        )

        coordinator.completePendingTransition(cancelled: false)
        await task.value
        _ = window
    }

    func testUnattachedNavigationControllerPreservesRequestedFalse() async {
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        original.reset()

        navigationController.setViewControllers(
            [root, detail],
            animated: false
        )
        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(original.lastWillShowAnimated, false)
        _ = window
    }

    func testAttachedSystemTransitionPreservesRequestedFalse() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        coordinator.attach(to: navigationController)
        original.reset()

        navigationController.setViewControllers(
            [root, detail],
            animated: false
        )
        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(original.lastWillShowAnimated, false)
        _ = window
    }

    func testRouterDrivenSystemPushForcesUIKitAnimationWhenRequestedFalse() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        coordinator.attach(to: navigationController)
        original.reset()

        await coordinator.perform(
            KVTransitionRequest(
                operation: .push,
                from: nil,
                to: KVNavigationEntry(route: TestRoute.screen("detail")),
                transitionOverride: .system
            )
        ) {
            navigationController.setViewControllers(
                [root, detail],
                animated: false
            )
        }
        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(original.lastWillShowAnimated, true)
        XCTAssertNil(coordinator.pendingTransaction)
        _ = window
    }

    func testDetachedNavigationControllerPreservesRequestedFalse() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .depth)
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        coordinator.attach(to: navigationController)
        coordinator.detach()
        original.reset()

        navigationController.setViewControllers(
            [root, detail],
            animated: false
        )
        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(original.lastWillShowAnimated, false)
        _ = window
    }

    func testDetachClearsUnconsumedSystemAnimationIntent() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        coordinator.attach(to: navigationController)

        await coordinator.perform(
            KVTransitionRequest(
                operation: .push,
                from: nil,
                to: KVNavigationEntry(route: TestRoute.screen("unused")),
                transitionOverride: .system
            )
        ) {}
        coordinator.detach()
        coordinator.attach(to: navigationController)
        original.reset()

        navigationController.setViewControllers(
            [root, detail],
            animated: false
        )
        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(original.lastWillShowAnimated, false)
        _ = window
    }

    func testNativeZoomTransitionForcesUIKitAnimationWhenRequestedFalse() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Native navigation zoom requires iOS 18 or newer")
        }

        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.hasSource = { $0 == AnyHashable("card") }
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        coordinator.attach(to: navigationController)
        original.reset()

        await coordinator.perform(
            KVTransitionRequest(
                operation: .push,
                from: nil,
                to: KVNavigationEntry(route: TestRoute.screen("detail")),
                transitionOverride: .zoom(sourceID: "card")
            )
        ) {
            navigationController.setViewControllers(
                [root, detail],
                animated: false
            )
        }
        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(original.lastWillShowAnimated, true)
        XCTAssertNil(coordinator.pendingTransaction)
        _ = window
    }

    func testInitialRootInstallationIsNotForcedByCustomTransaction() async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        let root = UIViewController()
        let navigationController = UINavigationController()
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        coordinator.attach(to: navigationController)
        original.reset()

        let task = Task { @MainActor in
            await coordinator.perform(
                KVTransitionRequest(
                    operation: .push,
                    from: nil,
                    to: KVNavigationEntry(route: TestRoute.screen("detail")),
                    transitionOverride: .depth
                )
            ) {
                navigationController.setViewControllers(
                    [root],
                    animated: false
                )
            }
        }

        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(original.lastWillShowAnimated, false)
        XCTAssertNil(coordinator.pendingTransaction?.animator)

        coordinator.completePendingTransition(cancelled: false)
        await task.value
        _ = window
    }

    func testInitialRootMutationDoesNotConsultForcingPolicy() {
        let navigationController = UINavigationController()
        let policy = RecordingNavigationAnimationPolicy()
        navigationController.kvInstallNavigationAnimationPolicy(policy)

        navigationController.setViewControllers(
            [UIViewController()],
            animated: false
        )

        XCTAssertTrue(policy.operations.isEmpty)
        navigationController.kvClearNavigationAnimationPolicy(policy)
    }

    func testRouterHostInstallsBridgeOnLiveNavigationStack() async throws {
        let router = KVAppRouter()
        let hostingController = UIHostingController(
            rootView: KVRouterHost(
                router: router,
                defaultTransition: .depth
            ) {
                Text("Root")
            }
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()

        let navigationController = try await waitForNavigationController(
            below: hostingController
        )

        XCTAssertTrue(
            navigationController.delegate is KVNavigationControllerDelegateProxy
        )
    }

    func testRouterCustomPushStartsUIKitAnimatedTransition() async throws {
        let router = KVAppRouter()
        let hostingController = UIHostingController(
            rootView: KVRouterHost(router: router) {
                Text("Root")
            }
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()

        let navigationController = try await waitForNavigationController(
            below: hostingController
        )

        router.pushView(transition: .depth) {
            Text("Detail")
        }

        let didStartAnimatedTransition = await waitUntilTrue {
            navigationController.transitionCoordinator != nil
        }
        XCTAssertTrue(didStartAnimatedTransition)

        let didRenderCustomOpacity = await waitUntilTrue {
            guard navigationController.viewControllers.count == 2,
                  let destination = navigationController.topViewController,
                  let opacity = destination.view.layer.presentation()?.opacity else {
                return false
            }
            return opacity > 0.01 && opacity < 0.99
        }
        XCTAssertTrue(didRenderCustomOpacity)
    }

    func testRouterSystemPushStartsUIKitAnimatedTransition() async throws {
        let router = KVAppRouter()
        let hostingController = UIHostingController(
            rootView: KVRouterHost(
                router: router,
                defaultTransition: .system
            ) {
                Text("Root")
            }
        )
        let window = makeVisibleWindow(rootViewController: hostingController)
        let navigationController = try await waitForNavigationController(
            below: hostingController
        )

        router.pushView(transition: .system) {
            Text("Detail")
        }

        let didStartAnimatedTransition = await waitUntilTrue {
            navigationController.transitionCoordinator?.isAnimated == true
        }
        XCTAssertTrue(didStartAnimatedTransition)
        _ = window
    }

    func testRouterSystemPopStartsUIKitAnimatedTransition() async throws {
        let router = KVAppRouter()
        let hostingController = UIHostingController(
            rootView: KVRouterHost(
                router: router,
                defaultTransition: .system
            ) {
                Text("Root")
            }
        )
        let window = makeVisibleWindow(rootViewController: hostingController)
        let navigationController = try await waitForNavigationController(
            below: hostingController
        )

        router.pushView(transition: .system) {
            Text("Detail")
        }
        let didFinishPush = await waitUntilTrue {
            navigationController.viewControllers.count == 2
                && navigationController.transitionCoordinator == nil
        }
        XCTAssertTrue(didFinishPush)

        router.pop()

        let didStartAnimatedTransition = await waitUntilTrue {
            navigationController.transitionCoordinator?.isAnimated == true
        }
        XCTAssertTrue(didStartAnimatedTransition)
        _ = window
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }

    private func waitForNavigationController(
        below root: UIViewController
    ) async throws -> UINavigationController {
        for _ in 0..<100 {
            if let navigationController = findNavigationController(below: root) {
                return navigationController
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("KVRouterHost did not create a UINavigationController")
        throw NavigationControllerLookupError.notFound
    }

    private func waitUntilTrue(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func makeVisibleWindow(
        rootViewController: UIViewController
    ) -> UIWindow {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        rootViewController.view.setNeedsLayout()
        rootViewController.view.layoutIfNeeded()
        return window
    }

    private func assertCustomPopForcesAnimation(
        _ mutation: @escaping @MainActor (
            UINavigationController,
            UIViewController
        ) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        let root = UIViewController()
        let detail = UIViewController()
        let navigationController = UINavigationController(
            rootViewController: root
        )
        navigationController.setViewControllers(
            [root, detail],
            animated: false
        )
        let original = RecordingNavigationDelegate()
        navigationController.delegate = original
        let window = makeVisibleWindow(rootViewController: navigationController)
        coordinator.attach(to: navigationController)
        original.reset()
        let entry = KVNavigationEntry(route: TestRoute.screen("detail"))

        let task = Task { @MainActor in
            await coordinator.perform(
                KVTransitionRequest(
                    operation: .pop,
                    from: entry,
                    to: nil,
                    transitionOverride: .depth
                )
            ) {
                mutation(navigationController, root)
            }
        }

        await waitUntil { original.lastWillShowAnimated != nil }

        XCTAssertEqual(
            original.lastWillShowAnimated,
            true,
            file: file,
            line: line
        )
        XCTAssertTrue(
            coordinator.pendingTransaction?.animator
                is KVViewControllerTransitionAnimator,
            file: file,
            line: line
        )

        coordinator.completePendingTransition(cancelled: false)
        await task.value
        _ = window
    }

    private func findNavigationController(
        below controller: UIViewController
    ) -> UINavigationController? {
        if let navigationController = controller as? UINavigationController {
            return navigationController
        }
        for child in controller.children {
            if let navigationController = findNavigationController(below: child) {
                return navigationController
            }
        }
        return controller.presentedViewController.flatMap {
            findNavigationController(below: $0)
        }
    }
}

private enum NavigationControllerLookupError: Error {
    case notFound
}

@MainActor
private final class RecordingNavigationAnimationPolicy:
    KVNavigationAnimationPolicy {
    private(set) var operations: [UINavigationController.Operation] = []

    func shouldForceAnimation(
        for operation: UINavigationController.Operation,
        from fromViewController: UIViewController?,
        to toViewController: UIViewController?
    ) -> Bool {
        operations.append(operation)
        return true
    }
}

@MainActor
private final class RecordingNavigationDelegate: NSObject,
    UINavigationControllerDelegate {
    private(set) var didShowCount = 0
    private(set) var lastWillShowAnimated: Bool?

    func reset() {
        didShowCount = 0
        lastWillShowAnimated = nil
    }

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        lastWillShowAnimated = animated
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        didShowCount += 1
    }
}
