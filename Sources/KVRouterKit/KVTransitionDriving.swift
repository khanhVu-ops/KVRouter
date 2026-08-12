import Foundation
import SwiftUI

struct KVTransitionRequest {
    let operation: KVTransitionOperation
    let from: KVNavigationEntry?
    let to: KVNavigationEntry?
    let transitionOverride: KVNavigationTransition?
}

@MainActor
protocol KVTransitionDriving: AnyObject {
    func perform(
        _ request: KVTransitionRequest,
        mutation: @escaping @MainActor () -> Void
    ) async

    /// Applies a stack change the user must not see.
    ///
    /// Used by the second half of an animated replace, which drops the screen
    /// underneath the one just pushed. Without this the drop picks up an animator
    /// of its own and the transition plays a second time.
    func performSilently(_ edit: @MainActor () -> Void)
}

extension KVTransitionDriving {
    func performSilently(_ edit: @MainActor () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, edit)
    }
}
