//
//  KVAppRouter.swift
//  KVRouterKit
//
//  Created by Khanh Vu.
//

// =============================================================
// KVRouter – Clean, Performant, and Ergonomic Router for SwiftUI
// iOS 16+
// =============================================================

import SwiftUI
import Foundation
import Observation
import KVRouterCore

// MARK: - ================================
// MARK: App Router
// MARK: ================================

/// Central navigation coordinator for the app.
///
/// **Features:**
/// - Type-safe navigation with your own ``KVRoute`` types
/// - Dynamic view support with `pushView { }`
/// - Middleware support for auth guards, logging, etc.
///
/// **Usage:**
/// ```swift
/// @Environment(\.router) private var router
///
/// // Push navigation
/// router.push(ShopRoute.cart)
/// router.pushView { CustomView() }
///
/// // Navigation control
/// router.pop()
/// router.popToRoot()
/// ```
///
/// - Note: The router manages the navigation stack only. Present modals with
///   SwiftUI's own `.sheet` / `.fullScreenCover`, which already model
///   presentation declaratively and need nothing from a router.
///
/// - Note: `@MainActor`-isolated. Navigation operations run through a FIFO queue,
///   so two rapid calls (e.g. `push` twice) keep their order even when async
///   middleware takes different amounts of time for each route.
///
/// **Observation:** On iOS 17+ the router participates in the `Observation`
/// framework exactly like an `@Observable` class, so a view reading `path`
/// re-renders only when the stack changes. On iOS 16 it falls back to
/// `ObservableObject`.
///
/// - Warning: The fallback is asymmetric. `@Environment(\.router)` does not
///   observe an `ObservableObject`, so a view that reads ``routes`` through the
///   environment updates on iOS 17+ but silently never updates on iOS 16.
///   Send commands rather than rendering from stack state; use
///   `@ObservedObject` if a view genuinely must.
@MainActor
public final class KVAppRouter: ObservableObject {

    // MARK: - Observation Backing

    /// Resolved once at init. Every property access then goes through one
    /// existential dispatch instead of an `if #available` plus an
    /// `as? ObservationRegistrar` unbox on the hot path.
    private let observation: any KVObservationStrategy = {
        if #available(iOS 17.0, *) { return KVModernObservation() }
        return KVLegacyObservation()
    }()

    /// Report a property read to the Observation system (iOS 17+, no-op on iOS 16).
    private func trackAccess<Member>(_ keyPath: KeyPath<KVAppRouter, Member>) {
        observation.access(self, keyPath: keyPath)
    }

    /// Run a mutation, notifying both observation systems:
    /// `objectWillChange` for iOS 16 / `@ObservedObject` clients, and the
    /// registrar for iOS 17+ Observation tracking.
    private func withTrackedMutation<Member>(
        _ keyPath: KeyPath<KVAppRouter, Member>,
        _ mutation: () -> Void
    ) {
        objectWillChange.send()
        observation.withMutation(self, keyPath: keyPath, mutation)
    }

    // MARK: - Navigation State

    private var _navigationEntries: [KVNavigationEntry] = []
    private var transitionOverrides: [UUID: KVNavigationTransition] = [:]

    /// The stack above the root, oldest first.
    ///
    /// - Important: A snapshot, **not** an observable property. See the warning
    ///   on the type about how observation differs between iOS 16 and 17+.
    public var routes: [any KVRoute] {
        _navigationEntries.map(\.route.base)
    }

    /// Type-erased stack, for the host binding and internal bookkeeping.
    var path: [AnyKVRoute] {
        get {
            trackAccess(\.path)
            return _navigationEntries.map(\.route)
        }
        set {
            reconcileEntries(with: newValue)
        }
    }

    var navigationEntries: [KVNavigationEntry] {
        get {
            trackAccess(\.path)
            return _navigationEntries
        }
        set {
            let oldEntries = _navigationEntries
            withTrackedMutation(\.path) { _navigationEntries = newValue }
            cleanupRemovedEntries(from: oldEntries, to: newValue)
            handlePathChange(
                from: oldEntries.map(\.route),
                to: newValue.map(\.route)
            )
        }
    }

    func transitionOverride(for entry: KVNavigationEntry) -> KVNavigationTransition? {
        transitionOverrides[entry.id]
    }

    /// Middleware chain for route interception.
    private let middlewares: [KVRouteMiddleware]

    weak var transitionDriver: (any KVTransitionDriving)?

    // MARK: - Dynamic View Builders

    /// Views pushed via `pushView { }`, keyed by ``KVDynamicViewRoute/id``.
    ///
    /// Tag and view type used to live in a parallel dictionary here; they are
    /// now fields on ``KVDynamicViewRoute`` itself, so there is nothing left to
    /// keep in sync.
    private var dynamicBuilders: [UUID: () -> AnyView] = [:]

    // MARK: - Serial Operation Queue

    /// Tail of the FIFO operation chain. Each navigation operation awaits the
    /// previous one before running, so async middleware cannot reorder two
    /// operations issued back-to-back.
    private var lastOperation: Task<Void, Never>?

    /// Bumped on every ``enqueue(_:)``. `Task` is a value type with no identity,
    /// so this is what lets ``settle()`` tell "the queue drained" apart from
    /// "the operation I awaited finished and queued another one".
    private var operationGeneration: UInt64 = 0

    // MARK: - Initialization

    /// Creates a new router instance.
    /// - Parameter middlewares: Route middlewares (auth guards, loggers, interstitial ads, etc.)
    public init(middlewares: [KVRouteMiddleware] = []) {
        self.middlewares = middlewares
    }

    // MARK: - Operation Queue

    /// Enqueue a navigation operation. Operations run strictly in FIFO order.
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = lastOperation
        operationGeneration += 1
        lastOperation = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// Wait until every queued navigation operation has finished.
    ///
    /// Navigation is fire-and-forget: `push` returns immediately while the work
    /// runs on the FIFO queue. Await this to observe the settled state instead
    /// of sleeping — in tests, or before persisting the path.
    public func settle() async {
        // Another caller can enqueue while this call is suspended, so awaiting
        // the tail once is not enough — keep going until no new operation
        // arrived. No operation enqueues another one today; the loop guards the
        // concurrent-caller case, and keeps holding if that ever changes.
        while true {
            let generation = operationGeneration
            guard let operation = lastOperation else { return }
            await operation.value
            if operationGeneration == generation { return }
        }
    }

    private func performNavigation(
        _ request: KVTransitionRequest,
        mutation: @escaping @MainActor () -> Void
    ) async {
        if let transitionDriver {
            await transitionDriver.perform(request, mutation: mutation)
        } else {
            mutation()
        }
    }

    // MARK: - Path Change Observation

    /// Flag to distinguish router-controlled pops from system-initiated pops
    private var isRouterControlledPop = false

    /// Handle system-initiated path changes (swipe-back, @Environment(\.dismiss))
    /// invoked directly from the `path` setter, and run middleware as side-effects.
    /// Note: System pops cannot be cancelled — middleware runs as post-pop callbacks.
    private func handlePathChange(from oldPath: [AnyKVRoute], to newPath: [AnyKVRoute]) {
        // Only trigger when popping (newPath is shorter)
        guard newPath.count < oldPath.count else { return }

        // Skip if this was a router-controlled pop (middleware already ran)
        guard !isRouterControlledPop else {
            isRouterControlledPop = false
            return
        }

        // Find routes that were removed by the system
        let removedRoutes = oldPath.suffix(from: newPath.count)

        // Run middleware as side-effects for each removed route
        for (index, route) in removedRoutes.enumerated().reversed() {
            let destination = Self.destinationBelow(
                removedIndex: index,
                oldPath: oldPath,
                newPath: newPath
            )
            Task { @MainActor in
                await self.applyPopMiddlewares(
                    from: route.base,
                    to: destination?.base
                )
            }
        }
    }

    /// The route a removed screen popped back to: the one directly below it,
    /// which for the deepest removal (index 0) is the new top of the stack.
    private static func destinationBelow(
        removedIndex index: Int,
        oldPath: [AnyKVRoute],
        newPath: [AnyKVRoute]
    ) -> AnyKVRoute? {
        if index == 0 { return newPath.last }
        return oldPath[newPath.count + index - 1]
    }

    private func reconcileEntries(with routes: [AnyKVRoute]) {
        let oldEntries = _navigationEntries
        let prefixCount = zip(oldEntries.map(\.route), routes)
            .prefix { $0 == $1 }
            .count
        let prefix = oldEntries.prefix(prefixCount)
        let suffix = routes.dropFirst(prefixCount).map { KVNavigationEntry(route: $0) }
        navigationEntries = Array(prefix) + suffix
    }

    private func makeEntry(
        route: any KVRoute,
        transition: KVNavigationTransition?
    ) -> KVNavigationEntry {
        let entry = KVNavigationEntry(route: route)
        transitionOverrides[entry.id] = transition
        return entry
    }

    private func cleanupRemovedEntries(
        from oldEntries: [KVNavigationEntry],
        to newEntries: [KVNavigationEntry]
    ) {
        let liveIDs = Set(newEntries.map(\.id))
        for entry in oldEntries where !liveIDs.contains(entry.id) {
            transitionOverrides[entry.id] = nil
            cleanupBuilder(for: entry.route)
        }
    }
}

// MARK: - ================================
// MARK: Observation Strategy
// MARK: ================================

/// Picks an observation backend once, at init, so the availability check never
/// runs on a property access. `KVLegacyObservation` is a pure no-op: on iOS 16
/// `objectWillChange` (sent by ``KVAppRouter/withTrackedMutation(_:_:)``) is the
/// only channel, which is what `@ObservedObject` / `@StateObject` listen to.
@MainActor
private protocol KVObservationStrategy: AnyObject {
    func access<Member>(
        _ router: KVAppRouter,
        keyPath: KeyPath<KVAppRouter, Member>
    )

    func withMutation<Member>(
        _ router: KVAppRouter,
        keyPath: KeyPath<KVAppRouter, Member>,
        _ mutation: () -> Void
    )
}

@available(iOS 17.0, *)
private final class KVModernObservation: KVObservationStrategy {
    private let registrar = ObservationRegistrar()

    func access<Member>(
        _ router: KVAppRouter,
        keyPath: KeyPath<KVAppRouter, Member>
    ) {
        registrar.access(router, keyPath: keyPath)
    }

    func withMutation<Member>(
        _ router: KVAppRouter,
        keyPath: KeyPath<KVAppRouter, Member>,
        _ mutation: () -> Void
    ) {
        registrar.withMutation(of: router, keyPath: keyPath, mutation)
    }
}

private final class KVLegacyObservation: KVObservationStrategy {
    func access<Member>(
        _ router: KVAppRouter,
        keyPath: KeyPath<KVAppRouter, Member>
    ) {}

    func withMutation<Member>(
        _ router: KVAppRouter,
        keyPath: KeyPath<KVAppRouter, Member>,
        _ mutation: () -> Void
    ) {
        mutation()
    }
}

// MARK: - ================================
// MARK: Observation Conformance (iOS 17+)
// MARK: ================================

/// On iOS 17+ the router is a first-class `Observable` — SwiftUI tracks
/// per-property reads in view bodies, matching `@Observable` behavior.
@available(iOS 17.0, *)
extension KVAppRouter: Observable {}

// MARK: - ================================
// MARK: Push Navigation
// MARK: ================================

extension KVAppRouter {

    /// Push a typed route onto the navigation stack.
    /// - Parameter route: The route to navigate to.
    public func push(_ route: any KVRoute) {
        push(route, transition: nil)
    }

    /// Push a typed route with a per-navigation transition override.
    public func push(
        _ route: any KVRoute,
        transition: KVNavigationTransition
    ) {
        push(route, transition: Optional(transition))
    }

    private func push(
        _ route: any KVRoute,
        transition: KVNavigationTransition?
    ) {
        enqueue { [weak self] in
            guard let self else { return }
            guard let finalRoute = await self.applyMiddlewares(to: route) else { return }
            let entry = self.makeEntry(route: finalRoute, transition: transition)
            let request = KVTransitionRequest(
                operation: .push,
                from: self.navigationEntries.last,
                to: entry,
                transitionOverride: transition
            )
            await self.performNavigation(request) {
                self.navigationEntries.append(entry)
            }
        }
    }

    /// Push a dynamically built view onto the navigation stack.
    ///
    /// The view is lazily built when the navigation occurs.
    /// - Parameters:
    ///   - tag: Optional tag so this screen can be targeted later with ``popTo(tag:)``.
    ///   - build: Closure that builds the view.
    public func pushView<V: View>(tag: String? = nil, _ build: @escaping () -> V) {
        pushView(tag: tag, transition: nil, build)
    }

    /// Push a dynamically built view with a per-navigation transition override.
    public func pushView<V: View>(
        tag: String? = nil,
        transition: KVNavigationTransition,
        _ build: @escaping () -> V
    ) {
        pushView(tag: tag, transition: Optional(transition), build)
    }

    private func pushView<V: View>(
        tag: String?,
        transition: KVNavigationTransition?,
        _ build: @escaping () -> V
    ) {
        let dynamicRoute = KVDynamicViewRoute(
            id: UUID(),
            tag: tag,
            typeName: String(reflecting: V.self)
        )
        enqueue { [weak self] in
            guard let self else { return }
            self.dynamicBuilders[dynamicRoute.id] = { AnyView(build()) }
            guard let finalRoute = await self.applyMiddlewares(to: dynamicRoute) else {
                self.dynamicBuilders[dynamicRoute.id] = nil
                return
            }
            // Middleware may have redirected to a different route — drop the
            // now-unused builder so it can't leak.
            if AnyKVRoute(finalRoute) != AnyKVRoute(dynamicRoute) {
                self.dynamicBuilders[dynamicRoute.id] = nil
            }
            let entry = self.makeEntry(route: finalRoute, transition: transition)
            let request = KVTransitionRequest(
                operation: .push,
                from: self.navigationEntries.last,
                to: entry,
                transitionOverride: transition
            )
            await self.performNavigation(request) {
                self.navigationEntries.append(entry)
            }
        }
    }

    /// Push an already-constructed view onto the navigation stack.
    ///
    /// The view is captured and built lazily.
    /// - Parameters:
    ///   - view: The view to push.
    ///   - tag: Optional tag so this screen can be targeted later with ``popTo(tag:)``.
    public func pushView<V: View>(_ view: V, tag: String? = nil) {
        pushView(tag: tag) { view }
    }

    /// Push an already-constructed view with a per-navigation transition override.
    public func pushView<V: View>(
        _ view: V,
        tag: String? = nil,
        transition: KVNavigationTransition
    ) {
        pushView(tag: tag, transition: transition) { view }
    }

    /// Replace the top route with a new route.
    /// - Parameter route: The route to replace with.
    public func replaceTop(with route: any KVRoute) {
        replaceTop(with: route, transition: nil)
    }

    /// Replace the top route with a per-navigation transition override.
    public func replaceTop(
        with route: any KVRoute,
        transition: KVNavigationTransition
    ) {
        replaceTop(with: route, transition: Optional(transition))
    }

    private func replaceTop(
        with route: any KVRoute,
        transition: KVNavigationTransition?
    ) {
        enqueue { [weak self] in
            guard let self else { return }
            guard let finalRoute = await self.applyMiddlewares(to: route) else { return }
            let entry = self.makeEntry(route: finalRoute, transition: transition)
            if self.navigationEntries.isEmpty {
                self.navigationEntries = [entry]
            } else {
                self.navigationEntries[self.navigationEntries.count - 1] = entry
            }
        }
    }

    /// Replace the top route with a dynamically built view.
    /// - Parameters:
    ///   - tag: Optional tag so this screen can be targeted later with ``popTo(tag:)``.
    ///   - build: Closure that builds the view.
    public func replaceTopWithView<V: View>(tag: String? = nil, _ build: @escaping () -> V) {
        replaceTopWithView(tag: tag, transition: nil, build)
    }

    /// Replace the top route with a dynamic view and transition override.
    public func replaceTopWithView<V: View>(
        tag: String? = nil,
        transition: KVNavigationTransition,
        _ build: @escaping () -> V
    ) {
        replaceTopWithView(tag: tag, transition: Optional(transition), build)
    }

    private func replaceTopWithView<V: View>(
        tag: String?,
        transition: KVNavigationTransition?,
        _ build: @escaping () -> V
    ) {
        let dynamicRoute = KVDynamicViewRoute(
            id: UUID(),
            tag: tag,
            typeName: String(reflecting: V.self)
        )
        enqueue { [weak self] in
            guard let self else { return }
            self.dynamicBuilders[dynamicRoute.id] = { AnyView(build()) }
            guard let finalRoute = await self.applyMiddlewares(to: dynamicRoute) else {
                self.dynamicBuilders[dynamicRoute.id] = nil
                return
            }
            if AnyKVRoute(finalRoute) != AnyKVRoute(dynamicRoute) {
                self.dynamicBuilders[dynamicRoute.id] = nil
            }
            let entry = self.makeEntry(route: finalRoute, transition: transition)
            if self.navigationEntries.isEmpty {
                self.navigationEntries = [entry]
            } else {
                self.navigationEntries[self.navigationEntries.count - 1] = entry
            }
        }
    }

    /// Set the entire navigation path.
    ///
    /// Applies middlewares to each route and cleans up orphaned builders.
    /// - Parameter routes: The new path.
    public func setPath(_ routes: [any KVRoute]) {
        enqueue { [weak self] in
            guard let self else { return }
            var transformed: [any KVRoute] = []
            for route in routes {
                if let finalRoute = await self.applyMiddlewares(to: route) {
                    transformed.append(finalRoute)
                }
            }
            self.cleanupOrphanedBuilders(newPath: transformed)
            self.path = transformed.map(AnyKVRoute.init)
        }
    }

}

// MARK: - ================================
// MARK: Pop Navigation
// MARK: ================================

extension KVAppRouter {

    /// Pop the top view from the navigation stack.
    /// Middleware can cancel this operation by returning `false`.
    public func pop() {
        enqueue { [weak self] in
            guard let self else { return }
            guard let fromEntry = self.navigationEntries.last else { return }
            let toEntry = self.navigationEntries.dropLast().last
            guard await self.applyPopMiddlewares(from: fromEntry.route.base, to: toEntry?.route.base) else { return }
            let request = KVTransitionRequest(
                operation: .pop,
                from: fromEntry,
                to: toEntry,
                transitionOverride: self.transitionOverride(for: fromEntry)
            )
            self.isRouterControlledPop = true
            await self.performNavigation(request) {
                self.navigationEntries.removeLast()
            }
        }
    }

    /// Pop to the root of the navigation stack.
    /// Middleware runs for the top route being popped.
    public func popToRoot() {
        enqueue { [weak self] in
            guard let self else { return }
            guard let fromEntry = self.navigationEntries.last else { return }
            guard await self.applyPopMiddlewares(from: fromEntry.route.base, to: nil) else { return }
            self.isRouterControlledPop = true
            self.navigationEntries = []
        }
    }

    /// Pop to a specific route in the navigation stack.
    ///
    /// If the route is not found, nothing happens.
    /// Middleware runs for the top route being popped.
    /// - Parameter route: The route to pop to.
    public func popTo(_ route: any KVRoute) {
        enqueue { [weak self] in
            guard let self else { return }
            let target = AnyKVRoute(route)
            guard let index = self._navigationEntries.firstIndex(where: { $0.route == target }) else { return }
            await self.performPop(toIndex: index)
        }
    }

    /// Pop to a route matching a predicate.
    /// Middleware runs for the top route being popped.
    /// - Parameter predicate: Condition to match the route.
    public func popTo(where predicate: @escaping (any KVRoute) -> Bool) {
        enqueue { [weak self] in
            guard let self else { return }
            guard let index = self._navigationEntries.lastIndex(where: { predicate($0.route.base) }) else { return }
            await self.performPop(toIndex: index)
        }
    }

    /// Pop back to the most recent screen pushed with the given tag.
    ///
    /// Matches views pushed via `pushView(tag:)` / `replaceTopWithView(tag:)`,
    /// and also typed `.appFeature(tag)` routes — so `popTo(tag: "profile")`
    /// finds both `pushView(tag: "profile") { … }` and `push(.appFeature("profile"))`.
    ///
    /// The current (top) screen is excluded from the search: this always means
    /// "go *back* to the tagged screen". If no screen below matches, nothing happens.
    /// Middleware can cancel via `willPop`.
    /// - Parameter tag: The tag to search for (nearest to the top wins).
    public func popTo(tag: String) {
        enqueue { [weak self] in
            guard let self else { return }
            guard let index = self._navigationEntries.dropLast()
                .lastIndex(where: { self.route($0.route, matchesTag: tag) }) else { return }
            await self.performPop(toIndex: index)
        }
    }

    /// Pop back to the most recent screen of the given view type pushed via `pushView`.
    ///
    /// ```swift
    /// router.pushView { DetailView(id: 1) }
    /// router.pushView { SettingsView() }
    /// router.popTo(DetailView.self) // back to DetailView(id: 1)
    /// ```
    ///
    /// No tag needed — the router records the concrete view type at push time.
    /// The current (top) screen is excluded from the search, so calling this
    /// *from* a `DetailView` pops back to the previous `DetailView` instance.
    /// If no screen below matches, nothing happens. Middleware can cancel via `willPop`.
    /// - Parameter viewType: The view type to search for (nearest to the top wins).
    public func popTo<V: View>(_ viewType: V.Type) {
        let typeName = String(reflecting: V.self)
        enqueue { [weak self] in
            guard let self else { return }
            guard let index = self._navigationEntries.dropLast()
                .lastIndex(where: { self.route($0.route, matchesViewType: typeName) }) else { return }
            await self.performPop(toIndex: index)
        }
    }

    // MARK: - Pop Helpers

    /// Shared pop-to-index body: runs pop middleware, then truncates the path
    /// and cleans up builders of the removed routes.
    private func performPop(toIndex index: Int) async {
        guard let fromEntry = navigationEntries.last else { return }
        let toEntry = navigationEntries[index]
        guard await applyPopMiddlewares(from: fromEntry.route.base, to: toEntry.route.base) else { return }
        isRouterControlledPop = true
        let removedCount = navigationEntries.count - index - 1
        guard removedCount == 1 else {
            self.navigationEntries = Array(self.navigationEntries.prefix(through: index))
            return
        }
        let request = KVTransitionRequest(
            operation: .pop,
            from: fromEntry,
            to: toEntry,
            transitionOverride: transitionOverride(for: fromEntry)
        )
        await performNavigation(request) {
            self.navigationEntries.removeLast()
        }
    }

    /// Whether a route is a dynamic view pushed with this tag.
    private func route(_ route: AnyKVRoute, matchesTag tag: String) -> Bool {
        route.unwrap(KVDynamicViewRoute.self)?.tag == tag
    }

    /// Whether a route is a dynamic view built from this view type.
    private func route(_ route: AnyKVRoute, matchesViewType typeName: String) -> Bool {
        route.unwrap(KVDynamicViewRoute.self)?.typeName == typeName
    }

    /// Pop a specific number of views from the stack.
    /// Middleware runs once for the top route being popped.
    /// - Parameter count: Number of views to pop.
    public func pop(count: Int) {
        enqueue { [weak self] in
            guard let self else { return }
            let removeCount = min(count, self._navigationEntries.count)
            guard removeCount > 0 else { return }
            guard let fromEntry = self.navigationEntries.last else { return }
            let targetIndex = self._navigationEntries.count - removeCount
            let toEntry = targetIndex > 0 ? self.navigationEntries[targetIndex - 1] : nil
            guard await self.applyPopMiddlewares(from: fromEntry.route.base, to: toEntry?.route.base) else { return }
            self.isRouterControlledPop = true
            guard removeCount == 1 else {
                self.navigationEntries = Array(self.navigationEntries.dropLast(removeCount))
                return
            }
            let request = KVTransitionRequest(
                operation: .pop,
                from: fromEntry,
                to: toEntry,
                transitionOverride: self.transitionOverride(for: fromEntry)
            )
            await self.performNavigation(request) {
                self.navigationEntries.removeLast()
            }
        }
    }

    func interactivePopRequest() -> KVTransitionRequest? {
        guard let from = navigationEntries.last else { return nil }
        let to = navigationEntries.dropLast().last
        return KVTransitionRequest(
            operation: .pop,
            from: from,
            to: to,
            transitionOverride: transitionOverride(for: from)
        )
    }

    func allowInteractivePop(_ request: KVTransitionRequest) async -> Bool {
        guard navigationEntries.last?.id == request.from?.id else { return false }
        return await applyPopMiddlewares(
            from: request.from?.route.base,
            to: request.to?.route.base
        )
    }

    func prepareInteractivePop(_ request: KVTransitionRequest) {
        guard navigationEntries.last?.id == request.from?.id else { return }
        isRouterControlledPop = true
    }

    func cancelInteractivePopPreparation() {
        isRouterControlledPop = false
    }

    func commitInteractivePop(_ request: KVTransitionRequest) -> Bool {
        guard navigationEntries.last?.id == request.from?.id else { return false }
        isRouterControlledPop = true
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        _ = withTransaction(transaction) {
            navigationEntries.removeLast()
        }
        return true
    }
}

// MARK: - ================================
// MARK: Dynamic View Building (Internal)
// MARK: ================================

extension KVAppRouter {

    /// The view for a `pushView { }` screen, or `nil` when its builder is gone.
    func dynamicView(for route: KVDynamicViewRoute) -> AnyView? {
        dynamicBuilders[route.id]?()
    }
}

// MARK: - ================================
// MARK: Middleware Chain
// MARK: ================================

extension KVAppRouter {

    /// Apply all middlewares to a route.
    /// - Parameter route: The route to process.
    /// - Returns: The transformed route, or nil if cancelled.
    private func applyMiddlewares(to route: any KVRoute) async -> (any KVRoute)? {
        let fromRoute: (any KVRoute)? = _navigationEntries.last?.route.base
        var candidate: (any KVRoute)? = route

        for middleware in middlewares {
            guard let current = candidate else { return nil }
            candidate = await middleware.willNavigate(from: fromRoute, to: current)
        }

        return candidate
    }

    /// Apply all middlewares for a pop operation.
    /// - Parameters:
    ///   - from: The route being popped.
    ///   - to: The route that will be on top after popping.
    /// - Returns: `true` if all middlewares allow the pop, `false` to cancel.
    @discardableResult
    func applyPopMiddlewares(from: (any KVRoute)?, to: (any KVRoute)?) async -> Bool {
        for middleware in middlewares {
            let allowed = await middleware.willPop(from: from, to: to)
            if !allowed { return false }
        }
        return true
    }

}

// MARK: - ================================
// MARK: Builder Cleanup Helpers
// MARK: ================================

private extension KVAppRouter {

    /// Drop the builder behind a route, when it is a dynamic view.
    func cleanupBuilder(for route: AnyKVRoute) {
        if let dynamic = route.unwrap(KVDynamicViewRoute.self) {
            dynamicBuilders[dynamic.id] = nil
        }
    }

    /// Drop builders for dynamic views the new path no longer contains.
    func cleanupOrphanedBuilders(newPath: [any KVRoute]) {
        let surviving = Set(newPath.compactMap { ($0 as? KVDynamicViewRoute)?.id })
        let current = Set(
            _navigationEntries.compactMap {
                $0.route.unwrap(KVDynamicViewRoute.self)?.id
            }
        )
        for id in current.subtracting(surviving) {
            dynamicBuilders[id] = nil
        }
    }
}
