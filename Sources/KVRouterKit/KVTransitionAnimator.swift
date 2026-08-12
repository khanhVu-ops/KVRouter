import SwiftUI
import UIKit

struct KVResolvedTransitionViewState {
    var alpha: CGFloat = 1
    var transform: CATransform3D = CATransform3DIdentity
    var translation: CGSize = .zero
    var cornerRadius: CGFloat?
    var zPosition: CGFloat?
    var revealOrigin: UnitPoint?
    var has3DTransform = false
}

extension KVTransitionViewState {
    func resolved(containerSize: CGSize) -> KVResolvedTransitionViewState {
        var result = KVResolvedTransitionViewState()

        for primitive in primitives {
            switch primitive {
            case .opacity(let value):
                result.alpha = value
            case .offset(let offset):
                result.translation.width += offset.width
                result.translation.height += offset.height
                result.transform = CATransform3DTranslate(
                    result.transform,
                    offset.width,
                    offset.height,
                    0
                )
            case .relativeOffset(let offset):
                let translation = CGSize(
                    width: offset.width * containerSize.width,
                    height: offset.height * containerSize.height
                )
                result.translation.width += translation.width
                result.translation.height += translation.height
                result.transform = CATransform3DTranslate(
                    result.transform,
                    translation.width,
                    translation.height,
                    0
                )
            case .scale(let scale):
                result.transform = CATransform3DScale(
                    result.transform,
                    scale.width,
                    scale.height,
                    1
                )
            case .rotation(let angle):
                result.transform = CATransform3DRotate(
                    result.transform,
                    angle,
                    0,
                    0,
                    1
                )
            case .rotation3D(let angle, let axis, let perspective):
                let dimension = max(containerSize.width, containerSize.height, 1)
                result.transform.m34 = -perspective / dimension
                result.transform = CATransform3DRotate(
                    result.transform,
                    angle,
                    axis.x,
                    axis.y,
                    axis.z
                )
                result.has3DTransform = true
            case .cornerRadius(let value):
                result.cornerRadius = value
            case .zPosition(let value):
                result.zPosition = value
            case .reveal(let origin):
                result.revealOrigin = origin
            }
        }

        return result
    }
}

@MainActor
final class KVManagedTransitionView {
    private struct Snapshot {
        let alpha: CGFloat
        let transform: CATransform3D
        let cornerRadius: CGFloat
        let masksToBounds: Bool
        let zPosition: CGFloat
        let mask: UIView?
        let isDoubleSided: Bool
        let isUserInteractionEnabled: Bool
    }

    let view: UIView
    private let snapshot: Snapshot
    private var transitionMask: UIView?

    init(_ view: UIView) {
        self.view = view
        snapshot = Snapshot(
            alpha: view.alpha,
            transform: view.layer.transform,
            cornerRadius: view.layer.cornerRadius,
            masksToBounds: view.layer.masksToBounds,
            zPosition: view.layer.zPosition,
            mask: view.mask,
            isDoubleSided: view.layer.isDoubleSided,
            isUserInteractionEnabled: view.isUserInteractionEnabled
        )
        view.isUserInteractionEnabled = false
    }

    func prepareReveal(
        for state: KVTransitionViewState,
        containerSize: CGSize
    ) {
        let resolved = state.resolved(containerSize: containerSize)
        guard let origin = resolved.revealOrigin else { return }
        let mask = makeMask(origin: origin)
        mask.transform = .identity
    }

    func apply(
        _ state: KVTransitionViewState,
        containerSize: CGSize
    ) {
        let resolved = state.resolved(containerSize: containerSize)
        view.alpha = resolved.alpha
        view.layer.transform = resolved.transform
        view.layer.cornerRadius = resolved.cornerRadius ?? snapshot.cornerRadius
        view.layer.masksToBounds = resolved.cornerRadius != nil
            ? true
            : snapshot.masksToBounds
        view.layer.zPosition = resolved.zPosition ?? snapshot.zPosition
        if resolved.has3DTransform {
            view.layer.isDoubleSided = false
        }

        if let origin = resolved.revealOrigin {
            let mask = transitionMask ?? makeMask(origin: origin)
            mask.transform = CGAffineTransform(scaleX: 0.001, y: 0.001)
        }
    }

    func applyIdentity() {
        view.alpha = snapshot.alpha
        view.layer.transform = snapshot.transform
        view.layer.cornerRadius = snapshot.cornerRadius
        view.layer.masksToBounds = snapshot.masksToBounds
        view.layer.zPosition = snapshot.zPosition
        transitionMask?.transform = .identity
    }

    func applyHero(
        _ geometry: KVHeroTransitionGeometry,
        fullFrame: CGRect
    ) {
        let resolved = geometry.resolvedState(for: fullFrame)
        view.alpha = snapshot.alpha
        view.layer.transform = CATransform3DConcat(
            snapshot.transform,
            resolved.transform
        )
        let minimumScale = max(
            min(resolved.scale.width, resolved.scale.height),
            0.001
        )
        view.layer.cornerRadius = resolved.cornerRadius / minimumScale
        view.layer.masksToBounds = true
    }

    func restore() {
        view.alpha = snapshot.alpha
        view.layer.transform = snapshot.transform
        view.layer.cornerRadius = snapshot.cornerRadius
        view.layer.masksToBounds = snapshot.masksToBounds
        view.layer.zPosition = snapshot.zPosition
        view.mask = snapshot.mask
        view.layer.isDoubleSided = snapshot.isDoubleSided
        view.isUserInteractionEnabled = snapshot.isUserInteractionEnabled
        transitionMask = nil
    }

    /// A `UIView`, not a `CALayer`, and that is load-bearing.
    ///
    /// `UIViewPropertyAnimator` animates *view* properties, so `mask.transform`
    /// on a `UIView` animates while the same change on a `CALayer` snaps straight
    /// to its final value — the reveal wipe stops being visible at all.
    ///
    /// The cost is a UIKit log: `view.mask = someView` makes UIKit add that view
    /// into the hierarchy, and these are `UIHostingController` views, so it warns
    /// that the arrangement is unsupported. Losing the animation is the worse of
    /// the two. Fixing both means masking a wrapper view this package owns
    /// instead of the hosting view, which is hierarchy surgery mid-transition.
    private func makeMask(origin: UnitPoint) -> UIView {
        let center = CGPoint(
            x: view.bounds.width * origin.x,
            y: view.bounds.height * origin.y
        )
        let farthestX = max(center.x, view.bounds.width - center.x)
        let farthestY = max(center.y, view.bounds.height - center.y)
        let radius = hypot(farthestX, farthestY)
        let diameter = max(radius * 2, 1)

        let mask = UIView(frame: CGRect(
            x: 0,
            y: 0,
            width: diameter,
            height: diameter
        ))
        mask.center = center
        mask.backgroundColor = .black
        mask.isUserInteractionEnabled = false
        mask.layer.cornerRadius = diameter / 2
        mask.layer.masksToBounds = true
        view.mask = mask
        transitionMask = mask
        return mask
    }
}

enum KVTransitionHierarchy {
    @MainActor
    static func install(
        operation: KVTransitionOperation,
        container: UIView,
        fromView: UIView,
        toView: UIView
    ) {
        switch operation {
        case .push:
            container.insertSubview(toView, aboveSubview: fromView)
        case .pop:
            container.insertSubview(toView, belowSubview: fromView)
        }
    }
}

@MainActor
final class KVViewControllerTransitionAnimator: NSObject,
    UIViewControllerAnimatedTransitioning {

    private let operation: KVTransitionOperation
    private let descriptor: KVTransitionDescriptor
    private let heroSourceProvider: (() -> KVTransitionSourceRegistry.Source?)?
    private let heroFallbackDescriptor: KVTransitionDescriptor?
    private let onCompletion: (Bool) -> Void
    private var cachedAnimators: [ObjectIdentifier: UIViewPropertyAnimator] = [:]

    init(
        operation: KVTransitionOperation,
        descriptor: KVTransitionDescriptor,
        heroSourceProvider: (() -> KVTransitionSourceRegistry.Source?)? = nil,
        heroFallbackDescriptor: KVTransitionDescriptor? = nil,
        onCompletion: @escaping (Bool) -> Void
    ) {
        self.operation = operation
        self.descriptor = descriptor
        self.heroSourceProvider = heroSourceProvider
        self.heroFallbackDescriptor = heroFallbackDescriptor
        self.onCompletion = onCompletion
    }

    func transitionDuration(
        using transitionContext: (any UIViewControllerContextTransitioning)?
    ) -> TimeInterval {
        descriptor.animation.duration
    }

    func animateTransition(
        using transitionContext: any UIViewControllerContextTransitioning
    ) {
        transitionAnimator(for: transitionContext).startAnimation()
    }

    func interruptibleAnimator(
        using transitionContext: any UIViewControllerContextTransitioning
    ) -> any UIViewImplicitlyAnimating {
        transitionAnimator(for: transitionContext)
    }

    func animationEnded(_ transitionCompleted: Bool) {
        cachedAnimators.removeAll(keepingCapacity: true)
    }

    private func transitionAnimator(
        for transitionContext: any UIViewControllerContextTransitioning
    ) -> UIViewPropertyAnimator {
        let key = ObjectIdentifier(transitionContext as AnyObject)
        if let cached = cachedAnimators[key] {
            return cached
        }

        let animator = UIViewPropertyAnimator(
            duration: descriptor.animation.duration,
            timingParameters: descriptor.animation.timingParameters
        )
        cachedAnimators[key] = animator

        guard let fromView = transitionContext.view(forKey: .from),
              let toView = transitionContext.view(forKey: .to) else {
            animator.addCompletion { [onCompletion] _ in
                transitionContext.completeTransition(false)
                onCompletion(true)
            }
            return animator
        }

        let container = transitionContext.containerView
        container.backgroundColor = toView.backgroundColor ?? .systemBackground

        if let fromController = transitionContext.viewController(forKey: .from) {
            fromView.frame = transitionContext.initialFrame(for: fromController)
        }
        if let toController = transitionContext.viewController(forKey: .to) {
            toView.frame = transitionContext.finalFrame(for: toController)
        }
        toView.setNeedsLayout()
        toView.layoutIfNeeded()

        KVTransitionHierarchy.install(
            operation: operation,
            container: container,
            fromView: fromView,
            toView: toView
        )
        container.layoutIfNeeded()
        toView.layoutIfNeeded()

        let heroGeometry = heroSourceProvider?()?.resolved(in: container)
        let activeDescriptor = heroSourceProvider != nil && heroGeometry == nil
            ? heroFallbackDescriptor ?? descriptor
            : descriptor

        let size = container.bounds.size
        let incoming = KVManagedTransitionView(toView)
        let outgoing = KVManagedTransitionView(fromView)
        if operation == .push, let heroGeometry {
            incoming.applyHero(heroGeometry, fullFrame: toView.frame)
        } else {
            incoming.apply(activeDescriptor.incoming.state, containerSize: size)
        }
        outgoing.prepareReveal(
            for: activeDescriptor.outgoing.state,
            containerSize: size
        )

        animator.addAnimations({
            incoming.applyIdentity()
        }, delayFactor: activeDescriptor.incomingDelayFactor)

        animator.addAnimations({
            if self.operation == .pop, let heroGeometry {
                outgoing.applyHero(heroGeometry, fullFrame: fromView.frame)
            } else {
                outgoing.apply(
                    activeDescriptor.outgoing.state,
                    containerSize: size
                )
            }
        }, delayFactor: activeDescriptor.outgoingDelayFactor)
        animator.addCompletion { [onCompletion] _ in
            let cancelled = transitionContext.transitionWasCancelled
            incoming.restore()
            outgoing.restore()
            transitionContext.completeTransition(!cancelled)

            // Reinsert the visible live view to keep hosting views responsive on iOS 16.
            let visibleView = cancelled ? fromView : toView
            visibleView.removeFromSuperview()
            container.addSubview(visibleView)
            onCompletion(cancelled)
        }

        return animator
    }
}
