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

// MARK: - ================================
// MARK: App Router
// MARK: ================================

/// Central navigation coordinator for the app.
///
/// **Features:**
/// - Type-safe navigation with `KVAppRoute` enum
/// - Dynamic view support with `pushView { }`
/// - Middleware support for auth guards, logging, etc.
/// - Deep link handling
///
/// **Usage:**
/// ```swift
/// @Environment(\.router) private var router
///
/// // Push navigation
/// router.push(.appFeature("profile"))
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
/// re-renders only when `path` changes. On iOS 16 it falls back to
/// `ObservableObject`.
///
/// - Warning: The fallback is asymmetric. `@Environment(\.router)` does not
///   observe an `ObservableObject`, so a view that reads `path` through the
///   environment updates on iOS 17+ but silently never updates on iOS 16.
///   Treat `path` as internal state and send commands instead; use
///   `@ObservedObject` if a view genuinely must render from it.
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

    /// Navigation stack path for push navigation.
    public var path: [KVAppRoute] {
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

    /// Host app: return a view for ``KVAppRoute/appFeature(_:)`` ids (e.g. `"profile"`). `nil` → ``EmptyView`` in ``buildView(for:)``.
    public var appFeatureViewBuilder: ((String) -> AnyView?)?

    /// Host app: return a view for ``KVAppRoute/deepLink(_:)`` payloads. `nil` → ``EmptyView``.
    public var deepLinkViewBuilder: ((String) -> AnyView?)?

    // MARK: - View Builder Registries

    /// Metadata for a custom pushed view — lets ``popTo(tag:)`` and
    /// ``popTo(_:)-view-type`` target dynamic views whose `.customView(UUID)`
    /// route is opaque to the caller.
    struct CustomViewInfo {
        /// Optional caller-chosen tag from `pushView(tag:)`.
        let tag: String?
        /// Fully qualified name of the concrete view type (e.g. `MyApp.DetailView`).
        let typeName: String
    }

    /// Registry for custom pushed views (keyed by UUID).
    private var customBuilders: [UUID: () -> AnyView] = [:]

    /// Metadata for custom pushed views (kept in sync with `customBuilders`).
    private var customViewInfo: [UUID: CustomViewInfo] = [:]

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
    private func handlePathChange(from oldPath: [KVAppRoute], to newPath: [KVAppRoute]) {
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
            let destination: KVAppRoute? = (newPath.count + index - 1 >= 0 && newPath.count + index - 1 < oldPath.count)
                ? (index == 0 ? newPath.last : oldPath[newPath.count + index - 1])
                : nil
            Task { @MainActor in
                await self.applyPopMiddlewares(from: route, to: destination)
            }
        }
    }

    private func reconcileEntries(with routes: [KVAppRoute]) {
        let oldEntries = _navigationEntries
        let prefixCount = zip(oldEntries.map(\.route), routes)
            .prefix { $0 == $1 }
            .count
        let prefix = oldEntries.prefix(prefixCount)
        let suffix = routes.dropFirst(prefixCount).map { KVNavigationEntry(route: $0) }
        navigationEntries = Array(prefix) + suffix
    }

    private func makeEntry(
        route: KVAppRoute,
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
    public func push(_ route: KVAppRoute) {
        push(route, transition: nil)
    }

    /// Push a typed route with a per-navigation transition override.
    public func push(
        _ route: KVAppRoute,
        transition: KVNavigationTransition
    ) {
        push(route, transition: Optional(transition))
    }

    private func push(
        _ route: KVAppRoute,
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
        let id = UUID()
        enqueue { [weak self] in
            guard let self else { return }
            self.customBuilders[id] = { AnyView(build()) }
            self.customViewInfo[id] = CustomViewInfo(tag: tag, typeName: String(reflecting: V.self))
            guard let finalRoute = await self.applyMiddlewares(to: .customView(id)) else {
                self.removeCustomView(id)
                return
            }
            // Middleware may have redirected to a different route — drop the
            // now-unused builder so it can't leak.
            if finalRoute != .customView(id) {
                self.removeCustomView(id)
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
    public func replaceTop(with route: KVAppRoute) {
        replaceTop(with: route, transition: nil)
    }

    /// Replace the top route with a per-navigation transition override.
    public func replaceTop(
        with route: KVAppRoute,
        transition: KVNavigationTransition
    ) {
        replaceTop(with: route, transition: Optional(transition))
    }

    private func replaceTop(
        with route: KVAppRoute,
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
        let id = UUID()
        enqueue { [weak self] in
            guard let self else { return }
            self.customBuilders[id] = { AnyView(build()) }
            self.customViewInfo[id] = CustomViewInfo(tag: tag, typeName: String(reflecting: V.self))
            guard let finalRoute = await self.applyMiddlewares(to: .customView(id)) else {
                self.removeCustomView(id)
                return
            }
            if finalRoute != .customView(id) {
                self.removeCustomView(id)
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
    public func setPath(_ routes: [KVAppRoute]) {
        enqueue { [weak self] in
            guard let self else { return }
            var transformed: [KVAppRoute] = []
            for route in routes {
                if let finalRoute = await self.applyMiddlewares(to: route) {
                    transformed.append(finalRoute)
                }
            }
            self.cleanupOrphanedBuilders(newPath: transformed)
            self.path = transformed
        }
    }

    /// Restore a persisted path (state restoration).
    ///
    /// Routes that cannot be rebuilt after decoding are dropped —
    /// `.customView` stores its view builder in memory only, so a decoded
    /// `.customView` would render ``EmptyView``. See ``KVAppRoute/isRestorable``.
    /// - Parameter routes: The decoded path to restore.
    public func restorePath(_ routes: [KVAppRoute]) {
        setPath(routes.filter(\.isRestorable))
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
            guard await self.applyPopMiddlewares(from: fromEntry.route, to: toEntry?.route) else { return }
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
            guard await self.applyPopMiddlewares(from: fromEntry.route, to: nil) else { return }
            self.isRouterControlledPop = true
            self.navigationEntries = []
        }
    }

    /// Pop to a specific route in the navigation stack.
    ///
    /// If the route is not found, nothing happens.
    /// Middleware runs for the top route being popped.
    /// - Parameter route: The route to pop to.
    public func popTo(_ route: KVAppRoute) {
        enqueue { [weak self] in
            guard let self else { return }
            guard let index = self._navigationEntries.firstIndex(where: { $0.route == route }) else { return }
            await self.performPop(toIndex: index)
        }
    }

    /// Pop to a route matching a predicate.
    /// Middleware runs for the top route being popped.
    /// - Parameter predicate: Condition to match the route.
    public func popTo(where predicate: @escaping (KVAppRoute) -> Bool) {
        enqueue { [weak self] in
            guard let self else { return }
            guard let index = self._navigationEntries.lastIndex(where: { predicate($0.route) }) else { return }
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
        guard await applyPopMiddlewares(from: fromEntry.route, to: toEntry.route) else { return }
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

    /// Whether a route matches a tag: custom views by their recorded tag,
    /// `.appFeature` by its id.
    private func route(_ route: KVAppRoute, matchesTag tag: String) -> Bool {
        switch route {
        case .customView(let id):
            return customViewInfo[id]?.tag == tag
        case .appFeature(let id):
            return id == tag
        case .deepLink:
            return false
        }
    }

    /// Whether a route is a custom view built from the given view type.
    private func route(_ route: KVAppRoute, matchesViewType typeName: String) -> Bool {
        guard case let .customView(id) = route else { return false }
        return customViewInfo[id]?.typeName == typeName
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
            guard await self.applyPopMiddlewares(from: fromEntry.route, to: toEntry?.route) else { return }
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
            from: request.from?.route,
            to: request.to?.route
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
// MARK: Deep Linking
// MARK: ================================

extension KVAppRouter {

    /// Handle a deep link URL.
    ///
    /// Forwards the URL as `.deepLink(payload)` only when `deepLinkViewBuilder` returns a view
    /// for that payload. Unknown or unconfigured payloads are ignored (no navigation change).
    ///
    /// - Important: `KVAppRouter` is `final`, so you can't override this method from the host app.
    ///   Use `deepLinkViewBuilder` instead.
    ///
    /// - Parameter url: The URL to handle.
    public func handle(url: URL) {
        guard let builder = deepLinkViewBuilder else { return }

        let payload = deepLinkPayload(from: url)
        guard !payload.isEmpty, builder(payload) != nil else { return }

        push(.deepLink(payload))
    }

    /// Convert an incoming URL into an opaque payload string.
    ///
    /// The host app can parse this payload inside `deepLinkViewBuilder`.
    private func deepLinkPayload(from url: URL) -> String {
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        var parts: [String] = []
        if let host = url.host, !host.isEmpty {
            parts.append(host)
        }
        parts.append(contentsOf: pathComponents)

        var payload = parts.joined(separator: "/")

        // Keep query as part of the payload for cases where the URL routing relies on it.
        if let query = url.query, !query.isEmpty {
            payload += "?\(query)"
        }

        return payload
    }
}

// MARK: - ================================
// MARK: View Building (Internal)
// MARK: ================================

extension KVAppRouter {

    /// Build a view for a push route.
    func buildCustomView(for id: UUID) -> AnyView {
        customBuilders[id]?() ?? AnyView(EmptyView())
    }

}

// MARK: - ================================
// MARK: Middleware Chain
// MARK: ================================

extension KVAppRouter {

    /// Apply all middlewares to a route.
    /// - Parameter route: The route to process.
    /// - Returns: The transformed route, or nil if cancelled.
    private func applyMiddlewares(to route: KVAppRoute) async -> KVAppRoute? {
        let fromRoute: KVAppRoute? = _navigationEntries.last?.route
        var candidate: KVAppRoute? = route

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
    func applyPopMiddlewares(from: KVAppRoute?, to: KVAppRoute?) async -> Bool {
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

    /// Remove a custom view's builder and metadata.
    func removeCustomView(_ id: UUID) {
        customBuilders[id] = nil
        customViewInfo[id] = nil
    }

    /// Clean up builder for a specific route if it's a custom view.
    func cleanupBuilder(for route: KVAppRoute) {
        if case let .customView(id) = route {
            removeCustomView(id)
        }
    }

    /// Clean up builders no longer in the new path.
    func cleanupOrphanedBuilders(newPath: [KVAppRoute]) {
        let newIDs = Set(newPath.compactMap { route -> UUID? in
            if case let .customView(id) = route { return id }
            return nil
        })
        let currentIDs = Set(_navigationEntries.compactMap { entry -> UUID? in
            if case let .customView(id) = entry.route { return id }
            return nil
        })
        currentIDs.subtracting(newIDs).forEach { removeCustomView($0) }
    }
}
