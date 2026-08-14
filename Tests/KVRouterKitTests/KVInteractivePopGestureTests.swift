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

    // MARK: - Where a pop swipe may start, and which drags count

    /// Drives `gestureRecognizerShouldBegin` for a drag starting `startX` points
    /// in from the leading edge.
    private func shouldBegin(
        startX: CGFloat,
        translation: CGPoint = CGPoint(x: 12, y: 0),
        velocity: CGPoint = CGPoint(x: 300, y: 0),
        edgeWidth: CGFloat? = nil
    ) -> Bool {
        let fixture = makeGestureFixture()
        if let edgeWidth {
            fixture.coordinator.interactivePopEdgeWidth = edgeWidth
        }
        let pan = StubPanGestureRecognizer()
        pan.stubLocation = CGPoint(x: startX, y: 300)
        pan.stubTranslation = translation
        pan.stubVelocity = velocity
        return fixture.controller.gestureRecognizerShouldBegin(pan)
    }

    func testAPopSwipeMayStartAnywhereInsideTheEdgeWidth() {
        XCTAssertTrue(shouldBegin(startX: 0))
        XCTAssertTrue(shouldBegin(startX: 20))
        // The point of the change: a screen-edge recognizer never saw this far in.
        XCTAssertTrue(shouldBegin(startX: 43))
    }

    func testAPopSwipeStartingBeyondTheEdgeWidthIsIgnored() {
        XCTAssertFalse(shouldBegin(startX: 45))
        XCTAssertFalse(shouldBegin(startX: 200))
    }

    func testTheEdgeWidthIsConfigurable() {
        XCTAssertFalse(shouldBegin(startX: 100))
        XCTAssertTrue(shouldBegin(startX: 100, edgeWidth: 120))
        // Narrowing it back down has to bite too.
        XCTAssertFalse(shouldBegin(startX: 20, edgeWidth: 8))
    }

    /// A slow, deliberate drag carries almost no velocity by the time UIKit asks.
    /// Gating on velocity alone rejected it, which is half of why this swipe was
    /// harder to catch than the system one.
    func testASlowDragStillBegins() {
        XCTAssertTrue(
            shouldBegin(
                startX: 10,
                translation: CGPoint(x: 9, y: 0),
                velocity: .zero
            )
        )
    }

    func testAVerticalOrBackwardDragDoesNotBegin() {
        // Mostly vertical: belongs to whatever scrolls.
        XCTAssertFalse(
            shouldBegin(startX: 10, translation: CGPoint(x: 3, y: 40))
        )
        // Towards the trailing edge: not a back swipe.
        XCTAssertFalse(
            shouldBegin(
                startX: 10,
                translation: CGPoint(x: -20, y: 0),
                velocity: CGPoint(x: -300, y: 0)
            )
        )
    }

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

    /// `attach` runs from the host's `.introspect`, i.e. while the stack is at
    /// root and UIKit keeps its own recognizer disabled because there is
    /// nothing to pop back to. Snapshotting that and using it to gate the
    /// enable latched the back swipe off forever — and since `.system` is the
    /// default transition, that was every app that never picked a custom one.
    func testSystemGestureIsReenabledEvenWhenItWasDisabledAtAttachTime() {
        let fixture = makeGestureFixture(
            defaultTransition: .system,
            systemGestureEnabledAtAttach: false
        )
        fixture.systemGesture.stubbedState = .possible

        fixture.controller.refreshAvailability()

        XCTAssertTrue(
            fixture.systemGesture.isEnabled,
            "A stack at root when the router attached must still swipe back once it is deeper"
        )
    }

    /// The host owns UIKit's recognizer while attached, so an app that wants no
    /// back swipe has to say so through the router — and saying so has to reach
    /// both engines, not just the custom one.
    func testHostOptOutSilencesBothEnginesForACustomTransition() {
        let fixture = makeGestureFixture(interactivePopEnabled: false)
        fixture.systemGesture.stubbedState = .possible

        fixture.controller.refreshAvailability()

        XCTAssertFalse(fixture.systemGesture.isEnabled)
        XCTAssertFalse(
            fixture.controller.begin(),
            "The custom engine must not drive a pop the host opted out of"
        )
    }

    /// The `.system` path is the one that can regress silently: an opted-out
    /// stack reads as "not custom", which is also what "UIKit's turn" looks
    /// like.
    func testHostOptOutSilencesTheSystemRecognizer() {
        let fixture = makeGestureFixture(
            defaultTransition: .system,
            interactivePopEnabled: false
        )
        fixture.systemGesture.stubbedState = .possible

        fixture.controller.refreshAvailability()

        XCTAssertFalse(fixture.systemGesture.isEnabled)
    }

    /// The flag is bindable to state, so the opt-out has to be reversible.
    func testTurningTheHostOptOutBackOnRestoresTheSystemRecognizer() {
        let fixture = makeGestureFixture(
            defaultTransition: .system,
            interactivePopEnabled: false
        )
        fixture.systemGesture.stubbedState = .possible
        fixture.controller.refreshAvailability()

        fixture.coordinator.interactivePopEnabled = true
        fixture.controller.refreshAvailability()

        XCTAssertTrue(fixture.systemGesture.isEnabled)
    }

    /// Detaching gives UIKit's recognizer back enabled rather than restoring
    /// what it read at attach — that read happens at root, where the recognizer
    /// is off, so restoring it left a navigation controller that can never
    /// swipe back.
    func testDetachHandsTheSystemRecognizerBackEnabled() {
        let fixture = makeGestureFixture(
            defaultTransition: .system,
            systemGestureEnabledAtAttach: false,
            interactivePopEnabled: false
        )
        fixture.systemGesture.stubbedState = .possible
        fixture.controller.refreshAvailability()
        XCTAssertFalse(fixture.systemGesture.isEnabled)

        fixture.controller.detach()

        XCTAssertTrue(fixture.systemGesture.isEnabled)
    }

    /// End-to-end through the bridge rather than the stubs: setting the flag is
    /// what refreshes availability, with no explicit call from the host.
    func testFlippingTheFlagRefreshesAvailabilityThroughTheBridge() {
        let router = KVAppRouter()
        router.path = [.screen("a"), .screen("b")]
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.router = router
        retained.append(router)
        retained.append(coordinator)
        let navigationController = UINavigationController()
        navigationController.viewControllers = [
            UIViewController(), UIViewController()
        ]
        // Deliberately not `loadViewIfNeeded()` first: `attach` has to reach
        // UIKit's recognizer on its own, or the opt-out no-ops in silence.
        coordinator.attach(to: navigationController)
        let systemGesture = navigationController.interactivePopGestureRecognizer

        coordinator.interactivePopEnabled = false

        XCTAssertEqual(systemGesture?.isEnabled, false)

        coordinator.interactivePopEnabled = true

        XCTAssertEqual(systemGesture?.isEnabled, true)
    }

    private func makeGestureFixture(
        defaultTransition: KVNavigationTransition = .depth,
        systemGestureEnabledAtAttach: Bool = true,
        interactivePopEnabled: Bool = true
    ) -> (
        controller: KVInteractiveTransitionController,
        coordinator: KVTransitionCoordinator,
        systemGesture: StubGestureRecognizer
    ) {
        let router = KVAppRouter()
        router.path = [.screen("a"), .screen("b")]
        let coordinator = KVTransitionCoordinator(
            defaultTransition: defaultTransition,
            interactivePopEnabled: interactivePopEnabled
        )
        coordinator.router = router
        retained.append(router)
        retained.append(coordinator)
        let navigationController = RecordingNavigationController()
        navigationController.viewControllers = [
            UIViewController(), UIViewController()
        ]
        let systemGesture = StubGestureRecognizer()
        systemGesture.isEnabled = systemGestureEnabledAtAttach
        let controller = KVInteractiveTransitionController(
            coordinator: coordinator,
            percentDrivenFactory: { RecordingPercentDrivenTransition() },
            systemGestureResolver: { _ in systemGesture }
        )
        controller.attach(to: navigationController)
        return (controller, coordinator, systemGesture)
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
/// Lets a test say exactly where a pan started and which way it went. The real
/// recognizer derives these from touches, which cannot be synthesised in a unit
/// test — and, as it turns out, not by simulator automation either.
private final class StubPanGestureRecognizer: UIPanGestureRecognizer {
    var stubLocation: CGPoint = .zero
    var stubTranslation: CGPoint = .zero
    var stubVelocity: CGPoint = .zero

    override func location(in view: UIView?) -> CGPoint { stubLocation }
    override func translation(in view: UIView?) -> CGPoint { stubTranslation }
    override func velocity(in view: UIView?) -> CGPoint { stubVelocity }
}

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
