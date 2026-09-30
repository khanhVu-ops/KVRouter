import UIKit

/// Stands in front of the delegate UIKit installs on the system back-swipe
/// recognizers (`interactivePopGestureRecognizer`, and on iOS 26
/// `interactiveContentPopGestureRecognizer`), so the back swipe on `.system`
/// survives a hidden navigation bar.
///
/// UIKit's own delegate refuses the swipe whenever the bar is hidden — the
/// common case for a SwiftUI app that draws its own header with
/// `.toolbar(.hidden, for: .navigationBar)`. Measured on iOS 26.2: the same swipe
/// pops with the bar shown and does nothing with it hidden. Screens on a custom
/// transition were never affected, because the router drives those itself.
///
/// The refusal does not come through any public delegate method. UIKit asks its
/// delegate an underscored question about the event first, and the answer is no
/// before `gestureRecognizer(_:shouldReceive:)` or `gestureRecognizerShouldBegin`
/// are ever consulted (measured: neither ran). So this wrapper declines every
/// underscored selector — it neither implements nor names one — which makes UIKit
/// fall back to the public questions answered here. Every other public question
/// is forwarded to UIKit's delegate unchanged.
///
/// The answers here allow a pop only when it is sound on its own: more than one
/// screen, no transition already running, nothing presented on top.
@MainActor
final class KVSystemPopGestureDelegate: NSObject, UIGestureRecognizerDelegate {

    /// UIKit's delegate. Weak, like the recognizer's own reference: the navigation
    /// controller owns it.
    ///
    /// `nonisolated(unsafe)` so the Objective-C forwarding hooks below can read it:
    /// UIKit only ever asks a recognizer's delegate on the main thread, and the
    /// value is set once, in `init`.
    nonisolated(unsafe) private(set) weak var original: UIGestureRecognizerDelegate?
    private weak var navigationController: UINavigationController?

    init(original: UIGestureRecognizerDelegate?, navigationController: UINavigationController) {
        self.original = original
        self.navigationController = navigationController
        super.init()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        canPop
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard canPop else { return false }
        return original?.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) ?? true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard canPop else { return false }
        if original?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true { return true }
        // UIKit's public answer can still be "no" for a hidden bar; that is the
        // one refusal this type exists to override.
        return navigationController?.isNavigationBarHidden == true
    }

    private var canPop: Bool {
        guard let navigationController,
              navigationController.viewControllers.count > 1,
              navigationController.transitionCoordinator == nil,
              navigationController.presentedViewController == nil
        else { return false }
        return true
    }

    // MARK: - Forwarding

    // Every other public delegate question (simultaneous recognition, failure
    // requirements) is UIKit's to answer. A selector is claimed only when UIKit's
    // delegate implements it, so the recognizer behaves as it did unwrapped —
    // except for underscored selectors, declined on purpose (see the type docs).

    nonisolated override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        guard !NSStringFromSelector(selector).hasPrefix("_") else { return false }
        return original?.responds(to: selector) ?? false
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        guard !NSStringFromSelector(selector).hasPrefix("_"),
              let original, original.responds(to: selector)
        else { return nil }
        return original
    }
}
