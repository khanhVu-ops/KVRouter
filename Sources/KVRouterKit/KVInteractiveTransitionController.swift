import UIKit

@MainActor
final class KVInteractiveTransitionController: NSObject,
    UIGestureRecognizerDelegate {
    private weak var coordinator: KVTransitionCoordinator?
    private weak var navigationController: UINavigationController?
    private weak var systemEdgePanGesture: UIGestureRecognizer?
    private var systemEdgePanWasEnabled = true
    private let percentDrivenFactory: () -> UIPercentDrivenInteractiveTransition
    private let systemGestureResolver: (UINavigationController) -> UIGestureRecognizer?
    private let edgePanGesture = UIScreenEdgePanGestureRecognizer()
    private var systemGestureRetry: Task<Void, Never>?

    private(set) var percentDriven: UIPercentDrivenInteractiveTransition?
    private var request: KVTransitionRequest?
    private var permissionTask: Task<Void, Never>?
    private var permissionResult: Bool?
    private var gestureWantsFinish = false
    private var gestureDidEnd = false
    private var isSettled = false
    private var endingVelocity: CGFloat = 0

    init(
        coordinator: KVTransitionCoordinator,
        percentDrivenFactory: @escaping () -> UIPercentDrivenInteractiveTransition = {
            UIPercentDrivenInteractiveTransition()
        },
        systemGestureResolver: @escaping (UINavigationController) -> UIGestureRecognizer? = {
            $0.interactivePopGestureRecognizer
        }
    ) {
        self.coordinator = coordinator
        self.percentDrivenFactory = percentDrivenFactory
        self.systemGestureResolver = systemGestureResolver
        super.init()
        edgePanGesture.addTarget(self, action: #selector(handleEdgePan(_:)))
        edgePanGesture.delegate = self
        edgePanGesture.maximumNumberOfTouches = 1
    }

    func attach(to navigationController: UINavigationController) {
        guard self.navigationController !== navigationController else {
            refreshAvailability()
            return
        }
        detach()
        self.navigationController = navigationController
        systemEdgePanGesture = systemGestureResolver(navigationController)
        systemEdgePanWasEnabled = systemEdgePanGesture?.isEnabled ?? true
        navigationController.view.addGestureRecognizer(edgePanGesture)
        refreshEdge()
        refreshAvailability()
    }

    func detach() {
        permissionTask?.cancel()
        permissionTask = nil
        systemGestureRetry?.cancel()
        systemGestureRetry = nil
        if edgePanGesture.view != nil {
            edgePanGesture.view?.removeGestureRecognizer(edgePanGesture)
        }
        systemEdgePanGesture?.isEnabled = systemEdgePanWasEnabled
        systemEdgePanGesture = nil
        navigationController = nil
        resetSession()
    }

    func refreshAvailability() {
        let usesCustomInteraction = coordinator?.canBeginInteractivePop() == true
        edgePanGesture.isEnabled = usesCustomInteraction
        setSystemGesture(
            enabled: systemEdgePanWasEnabled && !usesCustomInteraction
        )
        refreshEdge()
    }

    /// Toggles UIKit's own back-swipe recognizer, but never mid-recognition.
    ///
    /// UIKit drives its interactive transitions with that recognizer, and
    /// assigning `isEnabled` to a recognizer that is tracking touches cancels it
    /// on the spot. `refreshAvailability()` runs from
    /// `navigationControllerDidShow` — for a drag dismissal, exactly while the
    /// transition it is driving is settling — so the flip waits instead.
    ///
    /// Deferring is safe in a way that flipping early is not: the value is
    /// re-derived on every `refreshAvailability()`, and the retry re-reads it.
    private func setSystemGesture(enabled: Bool) {
        systemGestureRetry?.cancel()
        systemGestureRetry = nil
        guard let gesture = systemEdgePanGesture,
              gesture.isEnabled != enabled else {
            return
        }

        switch gesture.state {
        case .began, .changed, .ended:
            systemGestureRetry = Task { [weak self] in
                // A recognizer leaves .ended/.changed when UIKit finishes the
                // turn of the loop it is in, so one hop is normally enough; the
                // guard re-checks rather than assuming.
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                self?.setSystemGesture(enabled: enabled)
            }
        default:
            gesture.isEnabled = enabled
        }
    }

    func begin() -> Bool {
        guard request == nil,
              let coordinator,
              let navigationController,
              let request = coordinator.beginInteractivePop() else {
            return false
        }

        let percentDriven = percentDrivenFactory()
        percentDriven.completionCurve = .easeOut
        self.percentDriven = percentDriven
        self.request = request
        permissionResult = nil
        gestureWantsFinish = false
        gestureDidEnd = false
        isSettled = false
        endingVelocity = 0

        permissionTask = Task { [weak self, weak coordinator] in
            guard let coordinator else { return }
            let allowed = await coordinator.allowInteractivePop(request)
            guard !Task.isCancelled else { return }
            self?.permissionDidResolve(allowed)
        }

        guard navigationController.popViewController(animated: true) != nil else {
            permissionTask?.cancel()
            isSettled = true
            percentDriven.cancel()
            coordinator.completePendingTransition(cancelled: true)
            resetSession()
            return false
        }
        percentDriven.update(0)
        return true
    }

    func update(
        translation: CGFloat,
        width: CGFloat,
        isRightToLeft: Bool
    ) {
        guard !isSettled, let percentDriven else { return }
        percentDriven.update(Self.progress(
            translation: translation,
            width: width,
            isRightToLeft: isRightToLeft
        ))
    }

    func end(
        translation: CGFloat,
        velocity: CGFloat,
        width: CGFloat,
        isRightToLeft: Bool
    ) {
        guard !isSettled, percentDriven != nil else { return }
        let progress = Self.progress(
            translation: translation,
            width: width,
            isRightToLeft: isRightToLeft
        )
        let leadingVelocity = isRightToLeft ? -velocity : velocity
        endingVelocity = leadingVelocity
        gestureWantsFinish = Self.shouldFinish(
            progress: progress,
            velocity: leadingVelocity
        )
        gestureDidEnd = true
        settleIfReady()
    }

    func cancel() {
        guard !isSettled, let percentDriven else { return }
        isSettled = true
        permissionTask?.cancel()
        percentDriven.cancel()
    }

    func interactionController(
        for animationController: any UIViewControllerAnimatedTransitioning
    ) -> (any UIViewControllerInteractiveTransitioning)? {
        guard let transaction = coordinator?.pendingTransaction,
              transaction.isInteractive,
              transaction.animator === animationController else {
            return nil
        }
        return percentDriven
    }

    func transitionDidComplete() {
        resetSession()
        refreshAvailability()
    }

    static func progress(
        translation: CGFloat,
        width: CGFloat,
        isRightToLeft: Bool
    ) -> CGFloat {
        guard width > 0 else { return 0 }
        let leadingTranslation = isRightToLeft ? -translation : translation
        return min(max(leadingTranslation / width, 0), 1)
    }

    static func shouldFinish(
        progress: CGFloat,
        velocity: CGFloat
    ) -> Bool {
        progress >= 0.35 || velocity >= 800
    }

    func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let navigationController,
              navigationController.viewControllers.count > 1,
              navigationController.presentedViewController == nil,
              coordinator?.canBeginInteractivePop() == true,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return false
        }
        let velocity = pan.velocity(in: navigationController.view)
        let isRightToLeft = navigationController.view
            .effectiveUserInterfaceLayoutDirection == .rightToLeft
        let leadingVelocity = isRightToLeft ? -velocity.x : velocity.x
        return leadingVelocity > 0 && abs(velocity.x) > abs(velocity.y)
    }

    @objc
    private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let translation = gesture.translation(in: view).x
        let velocity = gesture.velocity(in: view).x
        let isRightToLeft = view.effectiveUserInterfaceLayoutDirection
            == .rightToLeft

        switch gesture.state {
        case .began:
            _ = begin()
        case .changed:
            update(
                translation: translation,
                width: view.bounds.width,
                isRightToLeft: isRightToLeft
            )
        case .ended:
            end(
                translation: translation,
                velocity: velocity,
                width: view.bounds.width,
                isRightToLeft: isRightToLeft
            )
        case .cancelled, .failed:
            cancel()
        case .possible:
            break
        @unknown default:
            cancel()
        }
    }

    private func permissionDidResolve(_ allowed: Bool) {
        permissionResult = allowed
        settleIfReady()
    }

    private func settleIfReady() {
        guard gestureDidEnd,
              let permissionResult,
              !isSettled,
              let percentDriven else {
            return
        }
        isSettled = true
        if gestureWantsFinish && permissionResult {
            let nominalSpeed = max(0.99, endingVelocity / 800)
            percentDriven.completionSpeed = min(nominalSpeed, 2.25)
            percentDriven.finish()
        } else {
            percentDriven.cancel()
        }
    }

    private func refreshEdge() {
        guard let navigationController else { return }
        edgePanGesture.edges = navigationController.view
            .effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? .right
            : .left
    }

    private func resetSession() {
        permissionTask?.cancel()
        permissionTask = nil
        percentDriven = nil
        request = nil
        permissionResult = nil
        gestureWantsFinish = false
        gestureDidEnd = false
        isSettled = false
        endingVelocity = 0
    }
}
