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

    // MARK: - System back swipe with a hidden navigation bar

    /// UIKit's delegate refuses the swipe whenever the bar is hidden; measured on
    /// iOS 26.2 — the same swipe popped with the bar shown and did nothing hidden.
    func testHiddenNavigationBarNoLongerBlocksTheSystemBackSwipe() {
        let fixture = makeSystemDelegateFixture(barHidden: true, screens: 2, originalAllows: false)
        XCTAssertTrue(fixture.gesture.delegate?.gestureRecognizerShouldBegin?(fixture.gesture) == true)
    }

    func testTheOverrideNeverPopsTheRoot() {
        let fixture = makeSystemDelegateFixture(barHidden: true, screens: 1, originalAllows: false)
        XCTAssertFalse(fixture.gesture.delegate?.gestureRecognizerShouldBegin?(fixture.gesture) == true)
    }

    /// With the bar shown a refusal is UIKit's own reason, and it stands.
    func testARefusalWithTheBarShownStands() {
        let fixture = makeSystemDelegateFixture(barHidden: false, screens: 2, originalAllows: false)
        XCTAssertFalse(fixture.gesture.delegate?.gestureRecognizerShouldBegin?(fixture.gesture) == true)
    }

    func testOtherDelegateQuestionsStillReachUIKitsDelegate() {
        let fixture = makeSystemDelegateFixture(barHidden: true, screens: 2, originalAllows: true)
        let other = UIPanGestureRecognizer()
        let answer = fixture.gesture.delegate?.gestureRecognizer?(
            fixture.gesture,
            shouldRecognizeSimultaneouslyWith: other
        )
        XCTAssertEqual(answer, true)
        XCTAssertEqual(fixture.original.simultaneousAsked, 1)
    }

    /// UIKit's refusal arrives through an underscored delegate question, before
    /// any public one. Declining those is what lets the public answers count.
    func testUnderscoredDelegateQuestionsAreDeclined() {
        let fixture = makeSystemDelegateFixture(barHidden: true, screens: 2, originalAllows: false)
        let wrapper = fixture.gesture.delegate as? NSObject
        XCTAssertEqual(wrapper?.responds(to: NSSelectorFromString("_gestureRecognizer:shouldReceiveEvent:")), false)
        XCTAssertEqual(wrapper?.responds(to: #selector(UIGestureRecognizerDelegate.gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:))), true)
    }

    func testTheEventIsReceivedOnlyWhenTheStackCanPop() {
        let poppable = makeSystemDelegateFixture(barHidden: true, screens: 2, originalAllows: false)
        XCTAssertEqual(poppable.gesture.delegate?.gestureRecognizer?(poppable.gesture, shouldReceive: UIEvent()), true)
        let root = makeSystemDelegateFixture(barHidden: true, screens: 1, originalAllows: true)
        XCTAssertEqual(root.gesture.delegate?.gestureRecognizer?(root.gesture, shouldReceive: UIEvent()), false)
    }

    /// iOS 26's pop-from-anywhere recognizer follows the edge one: off when the
    /// host opts out, and wrapped the same way.
    func testTheContentPopRecognizerIsWrappedAndFollowsTheOptOut() {
        let router = KVAppRouter()
        router.path = [.screen("a"), .screen("b")]
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.router = router
        let navigationController = RecordingNavigationController()
        navigationController.viewControllers = [UIViewController(), UIViewController()]
        let edge = StubGestureRecognizer()
        let content = StubGestureRecognizer()
        let original = StubGestureDelegate(allowsBegin: false)
        content.delegate = original
        let controller = KVInteractiveTransitionController(
            coordinator: coordinator,
            systemGestureResolver: { _ in edge },
            contentGestureResolver: { _ in content }
        )
        coordinator.interactivePopEnabled = true
        controller.attach(to: navigationController)
        retained.append(contentsOf: [router, coordinator, navigationController, original] as [AnyObject])

        XCTAssertTrue(content.delegate is KVSystemPopGestureDelegate)
        XCTAssertTrue(content.isEnabled)

        coordinator.interactivePopEnabled = false
        controller.refreshAvailability()
        XCTAssertFalse(content.isEnabled)

        controller.detach()
        XCTAssertTrue(content.delegate === original)
        XCTAssertTrue(content.isEnabled)
    }

    func testDetachHandsUIKitItsOwnDelegateBack() {
        let fixture = makeSystemDelegateFixture(barHidden: true, screens: 2, originalAllows: false)
        fixture.controller.detach()
        XCTAssertTrue(fixture.gesture.delegate === fixture.original)
    }

    private func makeSystemDelegateFixture(
        barHidden: Bool,
        screens: Int,
        originalAllows: Bool
    ) -> (controller: KVInteractiveTransitionController, gesture: StubGestureRecognizer, original: StubGestureDelegate) {
        let router = KVAppRouter()
        router.path = [.screen("a"), .screen("b")]
        let coordinator = KVTransitionCoordinator(defaultTransition: .system)
        coordinator.router = router
        let navigationController = RecordingNavigationController()
        navigationController.viewControllers = (0..<screens).map { _ in UIViewController() }
        navigationController.setNavigationBarHidden(barHidden, animated: false)
        let original = StubGestureDelegate(allowsBegin: originalAllows)
        let gesture = StubGestureRecognizer()
        gesture.delegate = original
        let controller = KVInteractiveTransitionController(
            coordinator: coordinator,
            systemGestureResolver: { _ in gesture }
        )
        controller.attach(to: navigationController)
        retained.append(contentsOf: [router, coordinator, navigationController, original] as [AnyObject])
        return (controller, gesture, original)
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

/// Plays UIKit's delegate on the system recognizer: says no to beginning when
/// told to (as UIKit does with the bar hidden) and counts what it is asked.
@MainActor
private final class StubGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    let allowsBegin: Bool
    private(set) var simultaneousAsked = 0

    init(allowsBegin: Bool) {
        self.allowsBegin = allowsBegin
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        allowsBegin
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        simultaneousAsked += 1
        return true
    }
}
