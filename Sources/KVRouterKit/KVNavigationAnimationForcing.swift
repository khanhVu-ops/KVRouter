import ObjectiveC.runtime
import UIKit

@MainActor
protocol KVNavigationAnimationPolicy: AnyObject {
    func shouldForceAnimation(
        for operation: UINavigationController.Operation,
        from fromViewController: UIViewController?,
        to toViewController: UIViewController?
    ) -> Bool
}

@MainActor
private final class KVNavigationAnimationPolicyBox {
    weak var policy: (any KVNavigationAnimationPolicy)?

    init(policy: any KVNavigationAnimationPolicy) {
        self.policy = policy
    }
}

private nonisolated(unsafe) var kvNavigationAnimationPolicyKey: UInt8 = 0

@MainActor
enum KVNavigationAnimationForcingRuntime {
    static func install() {
        _ = installOnce
    }

    private static let installOnce: Void = {
        let selectors: [(Selector, Selector)] = [
            (
                #selector(UINavigationController.setViewControllers(_:animated:)),
                #selector(UINavigationController.kvrouter_setViewControllers(_:animated:))
            ),
            (
                #selector(UINavigationController.pushViewController(_:animated:)),
                #selector(UINavigationController.kvrouter_pushViewController(_:animated:))
            ),
            (
                #selector(UINavigationController.popViewController(animated:)),
                #selector(UINavigationController.kvrouter_popViewController(animated:))
            ),
            (
                #selector(UINavigationController.popToViewController(_:animated:)),
                #selector(UINavigationController.kvrouter_popToViewController(_:animated:))
            ),
            (
                #selector(UINavigationController.popToRootViewController(animated:)),
                #selector(UINavigationController.kvrouter_popToRootViewController(animated:))
            ),
        ]

        let methods: [(Method, Method)] = selectors.compactMap { pair in
            let (original, exchanged) = pair
            guard let originalMethod = class_getInstanceMethod(
                UINavigationController.self,
                original
            ), let exchangedMethod = class_getInstanceMethod(
                UINavigationController.self,
                exchanged
            ) else {
                return nil
            }
            return (originalMethod, exchangedMethod)
        }

        guard methods.count == selectors.count else { return }
        for (original, exchanged) in methods {
            method_exchangeImplementations(original, exchanged)
        }
    }()
}

@MainActor
extension UINavigationController {
    func kvInstallNavigationAnimationPolicy(
        _ policy: any KVNavigationAnimationPolicy
    ) {
        KVNavigationAnimationForcingRuntime.install()
        objc_setAssociatedObject(
            self,
            &kvNavigationAnimationPolicyKey,
            KVNavigationAnimationPolicyBox(policy: policy),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    func kvClearNavigationAnimationPolicy(
        _ policy: any KVNavigationAnimationPolicy
    ) {
        guard kvNavigationAnimationPolicy === policy else { return }
        objc_setAssociatedObject(
            self,
            &kvNavigationAnimationPolicyKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    @objc
    fileprivate dynamic func kvrouter_setViewControllers(
        _ viewControllers: [UIViewController],
        animated: Bool
    ) {
        let mutation = kvClassifyMutation(to: viewControllers)
        let effectiveAnimated = animated || mutation.map {
            kvShouldForceAnimation(
                operation: $0.operation,
                from: $0.from,
                to: $0.to
            )
        } == true
        kvrouter_setViewControllers(
            viewControllers,
            animated: effectiveAnimated
        )
    }

    @objc
    fileprivate dynamic func kvrouter_pushViewController(
        _ viewController: UIViewController,
        animated: Bool
    ) {
        let effectiveAnimated = animated || kvShouldForceAnimation(
            operation: .push,
            from: topViewController,
            to: viewController
        )
        kvrouter_pushViewController(
            viewController,
            animated: effectiveAnimated
        )
    }

    @objc
    fileprivate dynamic func kvrouter_popViewController(
        animated: Bool
    ) -> UIViewController? {
        let effectiveAnimated = animated || kvShouldForceAnimation(
            operation: .pop,
            from: topViewController,
            to: viewControllers.dropLast().last
        )
        return kvrouter_popViewController(animated: effectiveAnimated)
    }

    @objc
    fileprivate dynamic func kvrouter_popToViewController(
        _ viewController: UIViewController,
        animated: Bool
    ) -> [UIViewController]? {
        let isSinglePop = viewControllers.dropLast().last === viewController
        let effectiveAnimated = animated || (
            isSinglePop && kvShouldForceAnimation(
                operation: .pop,
                from: topViewController,
                to: viewController
            )
        )
        return kvrouter_popToViewController(
            viewController,
            animated: effectiveAnimated
        )
    }

    @objc
    fileprivate dynamic func kvrouter_popToRootViewController(
        animated: Bool
    ) -> [UIViewController]? {
        let isSinglePop = viewControllers.count == 2
        let effectiveAnimated = animated || (
            isSinglePop && kvShouldForceAnimation(
                operation: .pop,
                from: topViewController,
                to: viewControllers.first
            )
        )
        return kvrouter_popToRootViewController(
            animated: effectiveAnimated
        )
    }

    private var kvNavigationAnimationPolicy: (any KVNavigationAnimationPolicy)? {
        (objc_getAssociatedObject(
            self,
            &kvNavigationAnimationPolicyKey
        ) as? KVNavigationAnimationPolicyBox)?.policy
    }

    private func kvShouldForceAnimation(
        operation: UINavigationController.Operation,
        from fromViewController: UIViewController?,
        to toViewController: UIViewController?
    ) -> Bool {
        kvNavigationAnimationPolicy?.shouldForceAnimation(
            for: operation,
            from: fromViewController,
            to: toViewController
        ) == true
    }

    private func kvClassifyMutation(
        to next: [UIViewController]
    ) -> (
        operation: UINavigationController.Operation,
        from: UIViewController?,
        to: UIViewController?
    )? {
        let previous = viewControllers

        if !previous.isEmpty,
           next.count == previous.count + 1,
           kvControllerPrefixMatches(previous, next) {
            return (.push, previous.last, next.last)
        }

        if previous.count == next.count + 1,
           kvControllerPrefixMatches(next, previous) {
            return (.pop, previous.last, next.last)
        }

        // Same depth, different top: a replace. UIKit has no `.replace`
        // operation and reports these as a push, so classify them that way.
        if !previous.isEmpty,
           previous.count == next.count,
           previous.last !== next.last,
           kvControllerPrefixMatches(previous.dropLast(), next.dropLast()) {
            return (.push, previous.last, next.last)
        }

        return nil
    }

    private func kvControllerPrefixMatches(
        _ prefix: [UIViewController],
        _ controllers: [UIViewController]
    ) -> Bool {
        zip(prefix, controllers).allSatisfy { left, right in
            left === right
        }
    }
}
