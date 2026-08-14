import SwiftUI
import UIKit

enum KVTransitionBackend: Equatable {
    case system
    case nativeZoom
    case custom

    @MainActor
    static func resolve(
        _ transition: KVNavigationTransition,
        supportsNativeZoom: Bool
    ) -> Self {
        switch transition.kind {
        case .system:
            return .system
        case .zoom where supportsNativeZoom:
            return .nativeZoom
        default:
            return .custom
        }
    }
}

struct KVResolvedTransition {
    let transition: KVNavigationTransition
    let backend: KVTransitionBackend
}

private struct KVControllerTransitionMetadata {
    weak var controller: UIViewController?
    let resolved: KVResolvedTransition
}

private struct KVNavigationAnimationIntent {
    let id = UUID()
    let request: KVTransitionRequest
}

@MainActor
final class KVTransitionTransaction {
    let id = UUID()
    let request: KVTransitionRequest
    let resolved: KVResolvedTransition
    let descriptor: KVTransitionDescriptor
    let isInteractive: Bool
    var animator: KVViewControllerTransitionAnimator?
    var continuation: CheckedContinuation<Void, Never>?
    var watchdog: Task<Void, Never>?

    init(
        request: KVTransitionRequest,
        resolved: KVResolvedTransition,
        descriptor: KVTransitionDescriptor,
        isInteractive: Bool = false
    ) {
        self.request = request
        self.resolved = resolved
        self.descriptor = descriptor
        self.isInteractive = isInteractive
    }
}

@MainActor
final class KVTransitionCoordinator: ObservableObject, KVTransitionDriving {
    let defaultTransition: KVNavigationTransition
    private(set) var pendingTransaction: KVTransitionTransaction?
    var isBridgeAttached = false
    var reduceMotion = false
    /// Host-level opt-out for back-swipe, covering both engines.
    ///
    /// The router owns UIKit's recognizer while it is attached, so an app that
    /// disables it directly gets it turned back on at the next availability
    /// refresh. This is the supported way to say no.
    var interactivePopEnabled = true {
        didSet {
            guard interactivePopEnabled != oldValue else { return }
            bridge?.refreshInteractivePopAvailability()
        }
    }
    var hasSource: (AnyHashable) -> Bool = { _ in false }
    weak var router: KVAppRouter? {
        didSet { bridge?.refreshInteractivePopAvailability() }
    }

    private var bridge: KVNavigationControllerBridge?
    private var nativeZoomEntryIDs: Set<UUID> = []
    private var navigationAnimationIntent: KVNavigationAnimationIntent?
    private var navigationAnimationIntentExpiry: Task<Void, Never>?

    /// Non-nil while a silent stack edit is in flight.
    ///
    /// A window rather than a synchronous scope: SwiftUI applies the path change
    /// and UIKit asks whether to animate it well after `performSilently` returns.
    private var silentEditToken: UUID?
    private var silentEditExpiry: Task<Void, Never>?

    private var isSilentEditing: Bool { silentEditToken != nil }
    // SwiftUI may remove the route before UIKit asks for its pop animator.
    private var controllerMetadata: [
        ObjectIdentifier: KVControllerTransitionMetadata
    ] = [:]

    var sourceRegistry: KVTransitionSourceRegistry? {
        didSet {
            let registry = sourceRegistry
            hasSource = { [weak registry] id in
                registry?.source(for: id) != nil
            }
        }
    }

    init(
        defaultTransition: KVNavigationTransition,
        interactivePopEnabled: Bool = true
    ) {
        self.defaultTransition = defaultTransition
        self.interactivePopEnabled = interactivePopEnabled
    }

    func attach(to navigationController: UINavigationController) {
        if let bridge {
            bridge.attach(to: navigationController)
        } else {
            let bridge = KVNavigationControllerBridge(coordinator: self)
            self.bridge = bridge
            bridge.attach(to: navigationController)
        }
        isBridgeAttached = true
    }

    func detach() {
        silentEditExpiry?.cancel()
        silentEditExpiry = nil
        silentEditToken = nil
        bridge?.detach()
        bridge = nil
        isBridgeAttached = false
        clearNavigationAnimationIntent()
        completePendingTransition(cancelled: true)
    }

    func resolve(
        override: KVNavigationTransition?,
        supportsNativeZoom: Bool
    ) -> KVResolvedTransition {
        let requested = override ?? defaultTransition
        if case .zoom(let sourceID) = requested.kind,
           !hasSource(sourceID.anyHashable) {
            return KVResolvedTransition(
                transition: .scaleAndFade,
                backend: .custom
            )
        }
        return KVResolvedTransition(
            transition: requested,
            backend: .resolve(requested, supportsNativeZoom: supportsNativeZoom)
        )
    }

    func resolve(
        _ request: KVTransitionRequest,
        supportsNativeZoom: Bool
    ) -> KVResolvedTransition {
        if request.operation == .pop,
           case .zoom = request.transitionOverride?.kind,
           let from = request.from {
            let transition = request.transitionOverride ?? defaultTransition
            return KVResolvedTransition(
                transition: transition,
                backend: supportsNativeZoom
                    && nativeZoomEntryIDs.contains(from.id)
                    ? .nativeZoom
                    : .custom
            )
        }

        return resolve(
            override: request.transitionOverride,
            supportsNativeZoom: supportsNativeZoom
        )
    }

    func usesNativeZoom(for entry: KVNavigationEntry) -> Bool {
        nativeZoomEntryIDs.contains(entry.id)
    }

    func perform(
        _ request: KVTransitionRequest,
        mutation: @escaping @MainActor () -> Void
    ) async {
        let resolved = resolve(
            request,
            supportsNativeZoom: Self.supportsNativeZoom
        )

        guard request.operation == .push || request.operation == .pop else {
            mutation()
            return
        }

        switch resolved.backend {
        case .system:
            prepareNavigationAnimationIntent(for: request)
            mutation()
            bridge?.refreshInteractivePopAvailability()
        case .nativeZoom:
            // Push only. The push needs the forcing: without it SwiftUI hands
            // UIKit `animated: false` and the zoom does not play at all.
            //
            // The pop must not have it. SwiftUI drives the zoom dismissal itself
            // and passes `animated: false` on purpose there; upgrading it made
            // UIKit run a second, concurrent transition, and SwiftUI never
            // un-hid the `matchedTransitionSource`. The source view stayed
            // invisible after the dismiss while still holding its slot in the
            // layout — a hole in the grid.
            if request.operation == .push {
                if let destination = request.to {
                    nativeZoomEntryIDs.insert(destination.id)
                }
                prepareNavigationAnimationIntent(for: request)
            }
            mutation()
            bridge?.refreshInteractivePopAvailability()
        case .custom:
            let descriptor = resolved.transition.descriptor(
                operation: request.operation,
                reduceMotion: reduceMotion
            )
            guard isBridgeAttached else {
                performAnimatedMutation(mutation, descriptor: descriptor)
                bridge?.refreshInteractivePopAvailability()
                return
            }

            let transaction = KVTransitionTransaction(
                request: request,
                resolved: resolved,
                descriptor: descriptor
            )
            pendingTransaction = transaction

            await withCheckedContinuation { continuation in
                transaction.continuation = continuation
                performAnimatedMutation(mutation, descriptor: descriptor)
                scheduleWatchdog(for: transaction)
            }
        }
    }

    func performSilently(_ edit: @MainActor () -> Void) {
        let token = UUID()
        silentEditToken = token
        clearNavigationAnimationIntent()
        silentEditExpiry?.cancel()
        silentEditExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard self?.silentEditToken == token else { return }
            self?.silentEditToken = nil
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, edit)
    }

    func animator(
        for operation: UINavigationController.Operation
    ) -> KVViewControllerTransitionAnimator? {
        guard !isSilentEditing else { return nil }
        guard let transaction = pendingTransaction,
              operation.matches(transaction.request.operation) else {
            return nil
        }
        if let animator = transaction.animator {
            return animator
        }

        let animator = makeAnimator(
            operation: transaction.request.operation,
            resolved: transaction.resolved,
            descriptor: transaction.descriptor
        ) { [weak self] cancelled in
            self?.completePendingTransition(
                id: transaction.id,
                cancelled: cancelled
            )
        }
        transaction.animator = animator
        return animator
    }

    func animator(
        for operation: UINavigationController.Operation,
        from fromViewController: UIViewController,
        to _: UIViewController
    ) -> KVViewControllerTransitionAnimator? {
        guard !isSilentEditing else { return nil }
        if let animator = animator(for: operation) {
            return animator
        }
        guard operation == .pop,
              let metadata = controllerMetadata[
                ObjectIdentifier(fromViewController)
              ],
              metadata.controller === fromViewController,
              metadata.resolved.backend == .custom else {
            return nil
        }

        let resolved = metadata.resolved
        let descriptor = resolved.transition.descriptor(
            operation: .pop,
            reduceMotion: reduceMotion
        )
        return makeAnimator(
            operation: .pop,
            resolved: resolved,
            descriptor: descriptor
        ) { _ in }
    }

    func shouldForceNavigationAnimation(
        for operation: UINavigationController.Operation,
        from fromViewController: UIViewController?,
        to _: UIViewController?
    ) -> Bool {
        guard !isSilentEditing else { return false }
        if let intent = navigationAnimationIntent,
           operation.matches(intent.request.operation) {
            navigationAnimationIntent = nil
            return true
        }

        if let transaction = pendingTransaction {
            return transaction.resolved.backend == .custom
                && operation.matches(transaction.request.operation)
        }

        guard operation == .pop,
              let fromViewController,
              let metadata = controllerMetadata[
                ObjectIdentifier(fromViewController)
              ],
              metadata.controller === fromViewController else {
            return false
        }
        // The same rule the router-driven pop follows in `perform`, applied to
        // the pops the router never sees: a swipe dismiss, the back button,
        // `@Environment(\.dismiss)`. This branch is only consulted when SwiftUI
        // hands UIKit `animated: false`, which for a native-zoom dismissal is
        // deliberate — SwiftUI drives that animation itself. Forcing it to true
        // starts a second, concurrent UIKit transition, and SwiftUI never
        // un-hides the `matchedTransitionSource`: the source view keeps its slot
        // in the layout and renders nothing.
        //
        // It matches the animator handed back for the same pop just above,
        // which has always declined native zoom.
        return metadata.resolved.backend != .nativeZoom
    }

    func synchronizeControllerMetadata(
        in navigationController: UINavigationController
    ) {
        let liveControllerIDs = Set(
            navigationController.viewControllers.map {
                ObjectIdentifier($0)
            }
        )
        controllerMetadata = controllerMetadata.filter { key, metadata in
            metadata.controller != nil && liveControllerIDs.contains(key)
        }

        guard let router else { return }
        let controllers = navigationController.viewControllers.dropFirst()
        let entries = router.navigationEntries
        for (index, pair) in zip(controllers, entries).enumerated() {
            let (controller, entry) = pair
            let transition = router.transitionOverride(for: entry)
                ?? defaultTransition
            let previousEntry = index > 0 ? entries[index - 1] : nil
            let request = KVTransitionRequest(
                operation: .pop,
                from: entry,
                to: previousEntry,
                transitionOverride: transition
            )
            controllerMetadata[ObjectIdentifier(controller)] =
                KVControllerTransitionMetadata(
                    controller: controller,
                    resolved: resolve(
                        request,
                        supportsNativeZoom: Self.supportsNativeZoom
                    )
                )
        }
    }

    private func makeAnimator(
        operation: KVTransitionOperation,
        resolved: KVResolvedTransition,
        descriptor: KVTransitionDescriptor,
        onCompletion: @escaping (Bool) -> Void
    ) -> KVViewControllerTransitionAnimator {
        KVViewControllerTransitionAnimator(
            operation: operation,
            descriptor: descriptor,
            heroSourceProvider: heroSourceProvider(
                for: resolved.transition
            ),
            heroFallbackDescriptor: KVNavigationTransition.scaleAndFade
                .descriptor(
                    operation: operation,
                    reduceMotion: reduceMotion
                ),
            onCompletion: onCompletion
        )
    }

    private func heroSourceProvider(
        for transition: KVNavigationTransition
    ) -> (() -> KVTransitionSourceRegistry.Source?)? {
        guard case .zoom(let sourceID) = transition.kind else { return nil }
        let id = sourceID.anyHashable
        return { [weak sourceRegistry] in
            sourceRegistry?.source(for: id)
        }
    }

    func navigationControllerDidShow(
        _ navigationController: UINavigationController
    ) {
        clearNavigationAnimationIntent()
        completePendingTransition(cancelled: false)
        synchronizeControllerMetadata(in: navigationController)
        // Prune here, not when the path changes. The path changes when an
        // interactive dismissal *commits*, which is before its animation ends,
        // and `usesNativeZoom(for:)` is what tells the destination to keep
        // `.navigationTransition(.zoom:)`. Dropping the entry early re-rendered
        // the destination without it mid-dismissal, and SwiftUI never un-hid the
        // `matchedTransitionSource` — the source stayed invisible. A button pop
        // was fast enough to finish before the re-render; a swipe was not.
        pruneEntryMetadata()
        bridge?.refreshInteractivePopAvailability()
    }

    private func pruneEntryMetadata() {
        guard let router else { return }
        nativeZoomEntryIDs.formIntersection(Set(router.navigationEntries.map(\.id)))
    }

    func completePendingTransition(cancelled: Bool) {
        guard let id = pendingTransaction?.id else { return }
        completePendingTransition(id: id, cancelled: cancelled)
    }

    /// Whether `entry` was pushed with the system zoom, kept until its
    /// transition finishes — see ``navigationControllerDidShow(_:)``.
    ///
    /// Without an attached bridge nothing prunes this, so the set grows by one
    /// UUID per zoom push for the life of the process. That is the cheaper side
    /// of the trade: pruning it on a path change is what broke swipe-to-dismiss.
    func retainedNativeZoomEntryCount() -> Int {
        nativeZoomEntryIDs.count
    }

    func canBeginInteractivePop() -> Bool {
        guard interactivePopEnabled,
              pendingTransaction == nil,
              let request = router?.interactivePopRequest() else {
            return false
        }
        let resolved = resolve(
            request,
            supportsNativeZoom: Self.supportsNativeZoom
        )
        return resolved.backend == .custom
            && resolved.transition.supportsInteractiveBack
    }

    func beginInteractivePop() -> KVTransitionRequest? {
        guard canBeginInteractivePop(),
              let router,
              let request = router.interactivePopRequest() else {
            return nil
        }
        let resolved = resolve(
            request,
            supportsNativeZoom: Self.supportsNativeZoom
        )
        let descriptor = resolved.transition.descriptor(
            operation: .pop,
            reduceMotion: reduceMotion
        )
        pendingTransaction = KVTransitionTransaction(
            request: request,
            resolved: resolved,
            descriptor: descriptor,
            isInteractive: true
        )
        router.prepareInteractivePop(request)
        return request
    }

    func allowInteractivePop(_ request: KVTransitionRequest) async -> Bool {
        guard let router else { return false }
        return await router.allowInteractivePop(request)
    }

    private func completePendingTransition(
        id: UUID,
        cancelled: Bool
    ) {
        guard let transaction = pendingTransaction,
              transaction.id == id else {
            return
        }
        transaction.watchdog?.cancel()
        transaction.watchdog = nil
        pendingTransaction = nil
        if transaction.isInteractive {
            if cancelled {
                router?.cancelInteractivePopPreparation()
            } else {
                _ = router?.commitInteractivePop(transaction.request)
            }
        }
        let continuation = transaction.continuation
        transaction.continuation = nil
        continuation?.resume()
        bridge?.refreshInteractivePopAvailability()
    }

    private func performAnimatedMutation(
        _ mutation: () -> Void,
        descriptor: KVTransitionDescriptor
    ) {
        withAnimation(.linear(duration: descriptor.animation.duration), mutation)
    }

    private func prepareNavigationAnimationIntent(
        for request: KVTransitionRequest
    ) {
        let intent = KVNavigationAnimationIntent(request: request)
        navigationAnimationIntent = intent
        navigationAnimationIntentExpiry?.cancel()
        navigationAnimationIntentExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.25))
            guard !Task.isCancelled,
                  self?.navigationAnimationIntent?.id == intent.id else { return }
            self?.navigationAnimationIntent = nil
        }
    }

    private func clearNavigationAnimationIntent() {
        navigationAnimationIntentExpiry?.cancel()
        navigationAnimationIntentExpiry = nil
        navigationAnimationIntent = nil
    }

    private func scheduleWatchdog(for transaction: KVTransitionTransaction) {
        guard pendingTransaction?.id == transaction.id else { return }
        let nanoseconds = UInt64(
            max(transaction.descriptor.animation.duration + 1, 1.25)
                * 1_000_000_000
        )
        transaction.watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.completePendingTransition(
                id: transaction.id,
                cancelled: false
            )
        }
    }

    private static var supportsNativeZoom: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

}

private extension UINavigationController.Operation {
    func matches(_ operation: KVTransitionOperation) -> Bool {
        switch (self, operation) {
        case (.push, .push), (.pop, .pop):
            return true
        default:
            return false
        }
    }
}
