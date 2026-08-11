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

    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        coordinator?.animator(
            for: operation,
            from: fromVC,
            to: toVC
        )
    }

    func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning
    ) -> (any UIViewControllerInteractiveTransitioning)? {
        interactiveController?.interactionController(
            for: animationController
        )
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector)
            || baseDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if baseDelegate?.responds(to: selector) == true {
            return baseDelegate
        }
        return super.forwardingTarget(for: selector)
    }
}
