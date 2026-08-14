import UIKit

@MainActor
final class KVNavigationControllerBridge: KVNavigationAnimationPolicy {
    private weak var navigationController: UINavigationController?
    private let coordinator: KVTransitionCoordinator
    private let interactiveController: KVInteractiveTransitionController
    private var delegateProxy: KVNavigationControllerDelegateProxy?

    init(coordinator: KVTransitionCoordinator) {
        self.coordinator = coordinator
        interactiveController = KVInteractiveTransitionController(
            coordinator: coordinator
        )
    }

    func attach(to navigationController: UINavigationController) {
        if self.navigationController !== navigationController {
            detach()
            self.navigationController = navigationController
        }
        navigationController.kvInstallNavigationAnimationPolicy(self)

        if let delegateProxy {
            delegateProxy.navigationController = navigationController
            guard navigationController.delegate !== delegateProxy else { return }
            delegateProxy.baseDelegate = navigationController.delegate
            navigationController.delegate = delegateProxy
            interactiveController.attach(to: navigationController)
            coordinator.synchronizeControllerMetadata(
                in: navigationController
            )
            return
        }

        let proxy = KVNavigationControllerDelegateProxy(
            coordinator: coordinator,
            baseDelegate: navigationController.delegate,
            interactiveController: interactiveController
        )
        proxy.navigationController = navigationController
        delegateProxy = proxy
        navigationController.delegate = proxy
        interactiveController.attach(to: navigationController)
        coordinator.synchronizeControllerMetadata(in: navigationController)
    }

    func detach() {
        navigationController?.kvClearNavigationAnimationPolicy(self)
        if let navigationController,
           let delegateProxy,
           navigationController.delegate === delegateProxy {
            navigationController.delegate = delegateProxy.baseDelegate
        }
        navigationController = nil
        delegateProxy = nil
        interactiveController.detach()
    }

    func refreshInteractivePopAvailability() {
        interactiveController.refreshAvailability()
    }

    /// Makes UIKit re-read which delegate callbacks the proxy claims.
    ///
    /// `UINavigationController` snapshots its delegate's `responds(to:)` answers
    /// when the delegate is assigned, so a proxy whose answer changes over time —
    /// which is how the system back swipe is kept alive on `.system`, see
    /// ``KVNavigationControllerDelegateProxy/responds(to:)`` — is invisible to it
    /// until the delegate is set again. Re-assigning is the only way to invalidate
    /// that snapshot; `nil` first, because assigning the same object is a no-op.
    func refreshDelegateCapabilities() {
        guard let navigationController,
              let delegateProxy,
              navigationController.delegate === delegateProxy else {
            return
        }
        navigationController.delegate = nil
        navigationController.delegate = delegateProxy
        // Assigning the delegate makes UIKit reconsider its own back-swipe
        // recognizer, which then competes with ours on screens where the router
        // drives the pop. Re-assert who owns the gesture.
        interactiveController.refreshAvailability()
    }

    func shouldForceAnimation(
        for operation: UINavigationController.Operation,
        from fromViewController: UIViewController?,
        to toViewController: UIViewController?
    ) -> Bool {
        coordinator.shouldForceNavigationAnimation(
            for: operation,
            from: fromViewController,
            to: toViewController
        )
    }
}

@MainActor
final class KVNavigationControllerDelegateProxy: NSObject,
    UINavigationControllerDelegate {
    nonisolated(unsafe) var baseDelegate: (any UINavigationControllerDelegate)?
    private weak var coordinator: KVTransitionCoordinator?
    private weak var interactiveController: KVInteractiveTransitionController?

    /// Which screen `responds(to:)` is answering about. Set by the bridge on
    /// attach; `nonisolated(unsafe)` for the same reason as `baseDelegate` —
    /// `responds(to:)` is a `nonisolated` override and UIKit only calls it on the
    /// main thread.
    nonisolated(unsafe) weak var navigationController: UINavigationController?

    init(
        coordinator: KVTransitionCoordinator,
        baseDelegate: (any UINavigationControllerDelegate)?,
        interactiveController: KVInteractiveTransitionController
    ) {
        self.coordinator = coordinator
        self.baseDelegate = baseDelegate
        self.interactiveController = interactiveController
    }

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        baseDelegate?.navigationController?(
            navigationController,
            willShow: viewController,
            animated: animated
        )
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        baseDelegate?.navigationController?(
            navigationController,
            didShow: viewController,
            animated: animated
        )
        coordinator?.navigationControllerDidShow(navigationController)
        interactiveController?.transitionDidComplete()
    }

    // Both of these forward when the router has nothing to contribute, so the
    // delegate this proxy wraps — SwiftUI's own — is wrapped rather than shadowed.
    //
    // Forwarding alone is not what keeps the system back swipe alive, though.
    // UIKit decides whether to run its own interactive pop from `responds(to:)`,
    // before either method is called; see the note on that override below.
    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        if let animator = coordinator?.animator(
            for: operation,
            from: fromVC,
            to: toVC
        ) {
            return animator
        }
        return baseDelegate?.navigationController?(
            navigationController,
            animationControllerFor: operation,
            from: fromVC,
            to: toVC
        )
    }

    func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning
    ) -> (any UIViewControllerInteractiveTransitioning)? {
        if let interaction = interactiveController?.interactionController(
            for: animationController
        ) {
            return interaction
        }
        return baseDelegate?.navigationController?(
            navigationController,
            interactionControllerFor: animationController
        )
    }

    /// The two transition selectors are claimed **only** when the router really
    /// has an animator for the navigation about to happen.
    ///
    /// UIKit suppresses `interactivePopGestureRecognizer` when the navigation
    /// controller's delegate merely *responds to*
    /// `navigationController(_:animationControllerFor:from:to:)` — whatever that
    /// method goes on to return. So a proxy that answers `true` unconditionally
    /// kills the back swipe on `.system`, where the router contributes nothing and
    /// UIKit's own default transition should run. Returning `nil` from the method
    /// is not a fix: UIKit never gets that far, and `interactionControllerFor` is
    /// never even called.
    ///
    /// Answered per screen rather than globally, so a stack that mixes custom and
    /// `.system` screens gets the right answer on each: the swipe works on the
    /// `.system` ones while the router still drives the custom ones.
    nonisolated override func responds(to selector: Selector!) -> Bool {
        if selector == Self.animationControllerSelector
            || selector == Self.interactionControllerSelector {
            // UIKit only asks on the main thread, and only about a live stack.
            let claimed = MainActor.assumeIsolated { claimsTransitionCallbacks }
            return claimed || baseDelegate?.responds(to: selector) == true
        }
        return super.responds(to: selector)
            || baseDelegate?.responds(to: selector) == true
    }

    @MainActor
    private var claimsTransitionCallbacks: Bool {
        coordinator?.contributesTransition(
            from: navigationController?.topViewController
        ) == true
    }

    nonisolated private static let animationControllerSelector = #selector(
        (any UINavigationControllerDelegate)
            .navigationController(_:animationControllerFor:from:to:)
    )

    nonisolated private static let interactionControllerSelector = #selector(
        (any UINavigationControllerDelegate)
            .navigationController(_:interactionControllerFor:)
    )

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if baseDelegate?.responds(to: selector) == true {
            return baseDelegate
        }
        return super.forwardingTarget(for: selector)
    }
}
