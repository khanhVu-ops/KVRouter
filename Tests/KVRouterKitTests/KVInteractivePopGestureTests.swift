import UIKit
import XCTest
import KVRouterCore
@testable import KVRouterKit

@MainActor
final class KVInteractivePopGestureTests: XCTestCase {
    /// The controller holds its coordinator weakly, and the coordinator holds
    /// the router weakly, so a fixture that only returns the controller loses
    /// both — and every interactive-pop check then reads false. Park them here.
    private var retained: [AnyObject] = []

    func testProgressClampsAndNormalizesLayoutDirection() {
        XCTAssertEqual(
            KVInteractiveTransitionController.progress(
                translation: 160,
                width: 320,
                isRightToLeft: false
            ),
            0.5
        )
        XCTAssertEqual(
            KVInteractiveTransitionController.progress(
                translation: -160,
                width: 320,
                isRightToLeft: true
            ),
            0.5
        )
        XCTAssertEqual(
            KVInteractiveTransitionController.progress(
                translation: -10,
                width: 320,
                isRightToLeft: false
            ),
            0
        )
    }

    func testInteractiveFinishUpdatesUIKitAndCommitsRouterOnce() async {
        let fixture = makeFixture()

        XCTAssertTrue(fixture.controller.begin())
        fixture.controller.update(
            translation: 160,
            width: 320,
            isRightToLeft: false
        )
        fixture.controller.end(
            translation: 160,
            velocity: 100,
            width: 320,
            isRightToLeft: false
        )
        await waitUntil { fixture.percentDriven.finishCount == 1 }

        XCTAssertEqual(fixture.percentDriven.updates.last, 0.5)
        XCTAssertEqual(fixture.percentDriven.finishCount, 1)
        XCTAssertEqual(fixture.percentDriven.cancelCount, 0)

        fixture.coordinator.completePendingTransition(cancelled: false)
        fixture.coordinator.completePendingTransition(cancelled: false)

        XCTAssertEqual(fixture.router.path, [.screen("a")])
    }

    func testMiddlewareDenialCancelsInteractivePop() async {
        let fixture = makeFixture(middlewares: [DenyPopMiddleware()])

        XCTAssertTrue(fixture.controller.begin())
        fixture.controller.update(
            translation: 280,
            width: 320,
            isRightToLeft: false
        )
        fixture.controller.end(
            translation: 280,
            velocity: 1_000,
            width: 320,
            isRightToLeft: false
        )
        await waitUntil { fixture.percentDriven.cancelCount == 1 }
        fixture.coordinator.completePendingTransition(cancelled: true)

        XCTAssertEqual(fixture.percentDriven.finishCount, 0)
        XCTAssertEqual(fixture.router.path.count, 2)
    }

    func testCancellationOnlyCancelsOnce() {
        let fixture = makeFixture()

        XCTAssertTrue(fixture.controller.begin())
        fixture.controller.cancel()
        fixture.controller.cancel()

        XCTAssertEqual(fixture.percentDriven.cancelCount, 1)
    }

    // MARK: - UIKit's own back-swipe recognizer

    /// `refreshAvailability()` runs from `navigationControllerDidShow`, which for
    /// a drag is while the recognizer UIKit is driving the transition with is
    /// still tracking — and assigning `isEnabled` there cancels it, killing the
    /// transition mid-settle.
    func testSystemGestureIsNotDisabledWhileItIsStillRecognizing() async {
        let fixture = makeGestureFixture()
        fixture.systemGesture.stubbedState = .changed
        // Attaching already disabled it, so start from UIKit owning the gesture
        // — the state this bug is about.
        fixture.systemGesture.isEnabled = true

        // The gallery below uses a custom transition, so availability wants the
        // system recognizer off.
        fixture.controller.refreshAvailability()

        XCTAssertTrue(
            fixture.systemGesture.isEnabled,
            "Disabling UIKit's recognizer mid-recognition cancels the transition it is driving"
        )

        fixture.systemGesture.stubbedState = .possible
        // The retry sleeps, so yielding is not enough to observe it.
        for _ in 0..<100 where fixture.systemGesture.isEnabled {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(
            fixture.systemGesture.isEnabled,
            "Once the recognizer settles the deferred change must still land"
        )
    }

    /// The other half: with nothing in flight the flip is immediate, so the
    /// custom edge pan owns the gesture from the first frame.
    func testSystemGestureIsDisabledImmediatelyWhenSettled() {
        let fixture = makeGestureFixture()
        fixture.systemGesture.stubbedState = .possible

        fixture.controller.refreshAvailability()

        XCTAssertFalse(fixture.systemGesture.isEnabled)
    }

    private func makeGestureFixture() -> (
        controller: KVInteractiveTransitionController,
        systemGesture: StubGestureRecognizer
    ) {
        let router = KVAppRouter()
        router.path = [.screen("a"), .screen("b")]
        let coordinator = KVTransitionCoordinator(defaultTransition: .depth)
        coordinator.router = router
        retained.append(router)
        retained.append(coordinator)
        let navigationController = RecordingNavigationController()
        navigationController.viewControllers = [
            UIViewController(), UIViewController()
        ]
        let systemGesture = StubGestureRecognizer()
        let controller = KVInteractiveTransitionController(
            coordinator: coordinator,
            percentDrivenFactory: { RecordingPercentDrivenTransition() },
            systemGestureResolver: { _ in systemGesture }
        )
        controller.attach(to: navigationController)
        return (controller, systemGesture)
    }

    private func makeFixture(
        middlewares: [KVRouteMiddleware] = []
    ) -> (
        router: KVAppRouter,
        coordinator: KVTransitionCoordinator,
        controller: KVInteractiveTransitionController,
        percentDriven: RecordingPercentDrivenTransition
    ) {
        let router = KVAppRouter(middlewares: middlewares)
        router.path = [.screen("a"), .screen("b")]
        let coordinator = KVTransitionCoordinator(defaultTransition: .depth)
        coordinator.router = router
        let navigationController = RecordingNavigationController()
        navigationController.viewControllers = [UIViewController(), UIViewController()]
        let percentDriven = RecordingPercentDrivenTransition()
        let controller = KVInteractiveTransitionController(
            coordinator: coordinator,
            percentDrivenFactory: { percentDriven }
        )
        controller.attach(to: navigationController)
        return (router, coordinator, controller, percentDriven)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }
}

private struct DenyPopMiddleware: KVRouteMiddleware {
    func willNavigate(
        from: (any KVRoute)?,
        to: any KVRoute
    ) async -> (any KVRoute)? {
        to
    }

    func willPop(from: (any KVRoute)?, to: (any KVRoute)?) async -> Bool {
        false
    }
}

@MainActor
private final class RecordingNavigationController: UINavigationController {
    private(set) var popCount = 0

    override func popViewController(animated: Bool) -> UIViewController? {
        popCount += 1
        return viewControllers.last
    }
}

@MainActor
private final class RecordingPercentDrivenTransition:
    UIPercentDrivenInteractiveTransition {
    private(set) var updates: [CGFloat] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    override func update(_ percentComplete: CGFloat) {
        updates.append(percentComplete)
    }

    override func finish() {
        finishCount += 1
    }

    override func cancel() {
        cancelCount += 1
    }
}

/// `state` is read-only from outside a recognizer, so the test drives it.
@MainActor
private final class StubGestureRecognizer: UIGestureRecognizer {
    var stubbedState: UIGestureRecognizer.State = .possible

    override var state: UIGestureRecognizer.State {
        get { stubbedState }
        set { stubbedState = newValue }
    }
}
