import Foundation

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
}
