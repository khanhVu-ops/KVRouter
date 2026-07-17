//
//  KVAppRouter.swift
//  KVRouter
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
/// - Modal presentation (sheets and full covers)
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
/// // Modal presentation
/// router.presentSheet { SettingsView() }
/// router.presentFullCover { OnboardingView() }
///
/// // Navigation control
/// router.pop()
/// router.popToRoot()
/// ```
///
/// - Note: `@MainActor`-isolated. Navigation operations run through a FIFO queue,
///   so two rapid calls (e.g. `push` twice) keep their order even when async
///   middleware takes different amounts of time for each route.
///
/// **Observation:** On iOS 17+ the router participates in the `Observation`
/// framework exactly like an `@Observable` class — views that read `path`,
/// `sheet`, or `fullCover` directly (e.g. via `@Environment(\.router)`) only
/// re-render when the property they read actually changes. On iOS 16 it falls
/// back to `ObservableObject`, so `@ObservedObject` / `@StateObject` keep working
/// everywhere.
@MainActor
public final class KVAppRouter: ObservableObject {

    // MARK: - Observation Backing

    /// `ObservationRegistrar` on iOS 17+, `nil` on iOS 16.
    /// Stored as `Any?` because the registrar type itself requires iOS 17.
    private let _registrar: Any? = {
        if #available(iOS 17.0, *) { return ObservationRegistrar() }
        return nil
    }()

    /// Report a property read to the Observation system (iOS 17+, no-op on iOS 16).
    private func trackAccess<Member>(_ keyPath: KeyPath<KVAppRouter, Member>) {
        if #available(iOS 17.0, *) {
            (_registrar as? ObservationRegistrar)?.access(self, keyPath: keyPath)
        }
    }

    /// Run a mutation, notifying both observation systems:
    /// `objectWillChange` for iOS 16 / `@ObservedObject` clients, and the
    /// registrar for iOS 17+ Observation tracking.
    private func withTrackedMutation<Member>(
        _ keyPath: KeyPath<KVAppRouter, Member>,
        _ mutation: () -> Void
    ) {
        objectWillChange.send()
        if #available(iOS 17.0, *), let registrar = _registrar as? ObservationRegistrar {
            registrar.withMutation(of: self, keyPath: keyPath, mutation)
        } else {
            mutation()
        }
    }

    // MARK: - Navigation State

    private var _path: [KVAppRoute] = []
    private var _sheet: KVSheetRoute?
    private var _fullCover: KVFullCoverRoute?

    /// Navigation stack path for push navigation.
    public var path: [KVAppRoute] {
        get {
            trackAccess(\.path)
            return _path
        }
        set {
            let oldValue = _path
            withTrackedMutation(\.path) { _path = newValue }
            handlePathChange(from: oldValue, to: newValue)
        }
    }

    /// Current sheet route (nil = no sheet presented).
    public var sheet: KVSheetRoute? {
        get {
            trackAccess(\.sheet)
            return _sheet
        }
        set {
            withTrackedMutation(\.sheet) { _sheet = newValue }
        }
    }

    /// Current full screen cover route (nil = no cover presented).
    public var fullCover: KVFullCoverRoute? {
        get {
            trackAccess(\.fullCover)
            return _fullCover
        }
        set {
            withTrackedMutation(\.fullCover) { _fullCover = newValue }
        }
    }

    /// Middleware chain for route interception.
    private let middlewares: [KVRouteMiddleware]

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

    /// Registry for custom sheet views.
    private var customSheetBuilders: [UUID: () -> AnyView] = [:]

    /// Registry for custom full cover views.
    private var customFullCoverBuilders: [UUID: () -> AnyView] = [:]

    // MARK: - Serial Operation Queue

    /// Tail of the FIFO operation chain. Each navigation operation awaits the
    /// previous one before running, so async middleware cannot reorder two
    /// operations issued back-to-back.
    private var lastOperation: Task<Void, Never>?

    /// Continuations waiting for the sheet dismissal animation to complete
    /// (resumed by ``sheetDidDismiss()`` or a timeout fallback).
    private var sheetDismissWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

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
        lastOperation = Task { @MainActor in
            await previous?.value
            await operation()
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

        // Clean up builders for removed routes to prevent memory leaks
        for route in removedRoutes {
            cleanupBuilder(for: route)
        }

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
        enqueue { [weak self] in
            guard let self else { return }
            guard let finalRoute = await self.applyMiddlewares(to: route) else { return }
            self.path.append(finalRoute)
        }
    }

    /// Push a dynamically built view onto the navigation stack.
    ///
    /// The view is lazily built when the navigation occurs.
    /// - Parameters:
    ///   - tag: Optional tag so this screen can be targeted later with ``popTo(tag:)``.
    ///   - build: Closure that builds the view.
    public func pushView<V: View>(tag: String? = nil, _ build: @escaping () -> V) {
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
            self.path.append(finalRoute)
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

    /// Replace the top route with a new route.
    /// - Parameter route: The route to replace with.
    public func replaceTop(with route: KVAppRoute) {
        enqueue { [weak self] in
            guard let self else { return }
            guard let finalRoute = await self.applyMiddlewares(to: route) else { return }
            // Clean up only after middleware approves, so a cancelled
            // navigation doesn't strand the current top view without its builder.
            self.cleanupTopBuilderIfNeeded()

            if self.path.isEmpty {
                self.path = [finalRoute]
            } else {
                self.path[self.path.count - 1] = finalRoute
            }
        }
    }

    /// Replace the top route with a dynamically built view.
    /// - Parameters:
    ///   - tag: Optional tag so this screen can be targeted later with ``popTo(tag:)``.
    ///   - build: Closure that builds the view.
    public func replaceTopWithView<V: View>(tag: String? = nil, _ build: @escaping () -> V) {
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
            // Clean up only after middleware approves (see `replaceTop(with:)`).
            self.cleanupTopBuilderIfNeeded()
            if self.path.isEmpty {
                self.path = [finalRoute]
            } else {
                self.path[self.path.count - 1] = finalRoute
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
            guard !self.path.isEmpty else { return }
            let from = self.path.last
            let to = self.path.count >= 2 ? self.path[self.path.count - 2] : nil
            guard await self.applyPopMiddlewares(from: from, to: to) else { return }
            self.isRouterControlledPop = true
            let last = self.path.removeLast()
            self.cleanupBuilder(for: last)
        }
    }

    /// Pop to the root of the navigation stack.
    /// Middleware runs for the top route being popped.
    public func popToRoot() {
        enqueue { [weak self] in
            guard let self else { return }
            guard !self.path.isEmpty else { return }
            let from = self.path.last
            guard await self.applyPopMiddlewares(from: from, to: nil) else { return }
            self.isRouterControlledPop = true
            self.path.forEach { self.cleanupBuilder(for: $0) }
            self.path.removeAll(keepingCapacity: true)
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
            guard let index = self.path.firstIndex(of: route) else { return }
            await self.performPop(toIndex: index)
        }
    }

    /// Pop to a route matching a predicate.
    /// Middleware runs for the top route being popped.
    /// - Parameter predicate: Condition to match the route.
    public func popTo(where predicate: @escaping (KVAppRoute) -> Bool) {
        enqueue { [weak self] in
            guard let self else { return }
            guard let index = self.path.lastIndex(where: predicate) else { return }
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
            guard let index = self.path.dropLast().lastIndex(where: { self.route($0, matchesTag: tag) }) else { return }
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
            guard let index = self.path.dropLast().lastIndex(where: { self.route($0, matchesViewType: typeName) }) else { return }
            await self.performPop(toIndex: index)
        }
    }

    // MARK: - Pop Helpers

    /// Shared pop-to-index body: runs pop middleware, then truncates the path
    /// and cleans up builders of the removed routes.
    private func performPop(toIndex index: Int) async {
        let from = path.last
        let to = path[index]
        guard await applyPopMiddlewares(from: from, to: to) else { return }
        isRouterControlledPop = true
        cleanupBuilders(from: index + 1)
        path = Array(path.prefix(through: index))
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
            let removeCount = min(count, self.path.count)
            guard removeCount > 0 else { return }
            let from = self.path.last
            let targetIndex = self.path.count - removeCount
            let to: KVAppRoute? = targetIndex > 0 ? self.path[targetIndex - 1] : nil
            guard await self.applyPopMiddlewares(from: from, to: to) else { return }
            self.isRouterControlledPop = true
            for _ in 0..<removeCount {
                guard let last = self.path.popLast() else { break }
                self.cleanupBuilder(for: last)
            }
        }
    }
}

// MARK: - ================================
// MARK: Sheet Presentation
// MARK: ================================

extension KVAppRouter {

    /// Present a typed sheet route.
    /// - Parameter sheet: The sheet route to present.
    public func present(_ sheet: KVSheetRoute) {
        enqueue { [weak self] in
            self?.sheet = sheet
        }
    }

    /// Present a dynamically built view as a sheet.
    /// - Parameter build: Closure that builds the sheet content.
    public func presentSheet<V: View>(_ build: @escaping () -> V) {
        let id = UUID()
        enqueue { [weak self] in
            guard let self else { return }
            self.customSheetBuilders[id] = { AnyView(build()) }
            self.sheet = .customSheet(id)
        }
    }

    /// Present an already-constructed view as a sheet.
    /// - Parameter view: The view to present.
    public func presentSheet<V: View>(_ view: V) {
        presentSheet { view }
    }

    /// Dismiss the current sheet.
    /// Middleware can cancel this operation by returning `false`.
    /// Builder cleanup happens after the dismissal animation completes (see ``sheetDidDismiss()``).
    public func dismissSheet() {
        enqueue { [weak self] in
            guard let self else { return }
            guard let current = self.sheet else { return }
            guard await self.applyDismissMiddlewares(sheet: current, fullCover: nil) else { return }
            self.sheet = nil
        }
    }

    /// Dismiss the current sheet and execute a callback.
    /// Middleware can cancel this operation by returning `false`;
    /// the callback only runs when the dismissal actually happens.
    /// - Parameter action: Callback to execute after dismissal.
    public func dismissSheet(afterDismiss action: @escaping () -> Void) {
        enqueue { [weak self] in
            guard let self else { return }
            guard let current = self.sheet else { return }
            guard await self.applyDismissMiddlewares(sheet: current, fullCover: nil) else { return }
            self.sheet = nil
            action()
        }
    }
}

// MARK: - ================================
// MARK: Full Screen Cover Presentation
// MARK: ================================

extension KVAppRouter {

    /// Present a typed full screen cover route.
    /// - Parameter cover: The cover route to present.
    public func presentFull(_ cover: KVFullCoverRoute) {
        enqueue { [weak self] in
            self?.fullCover = cover
        }
    }

    /// Present a dynamically built view as a full screen cover.
    ///
    /// If a sheet is currently presented, it is dismissed first and the cover
    /// is presented once the dismissal animation actually completes (signalled
    /// by ``KVRouterHost``), with a short timeout fallback when no host is attached.
    /// - Parameter build: Closure that builds the cover content.
    public func presentFullCover<V: View>(_ build: @escaping () -> V) {
        enqueue { [weak self] in
            guard let self else { return }
            if self.sheet != nil {
                self.sheet = nil
                await self.awaitSheetDismissal()
            }
            let id = UUID()
            self.customFullCoverBuilders[id] = { AnyView(build()) }
            self.fullCover = .customFullCover(id)
        }
    }

    /// Present an already-constructed view as a full screen cover.
    /// - Parameter view: The view to present.
    public func presentFullCover<V: View>(_ view: V) {
        presentFullCover { view }
    }

    /// Dismiss the current full screen cover.
    /// Middleware can cancel this operation by returning `false`.
    /// Builder cleanup happens after the dismissal animation completes (see ``fullCoverDidDismiss()``).
    public func dismissFull() {
        enqueue { [weak self] in
            guard let self else { return }
            guard let current = self.fullCover else { return }
            guard await self.applyDismissMiddlewares(sheet: nil, fullCover: current) else { return }
            self.fullCover = nil
        }
    }

    /// Dismiss sheet and then present a full screen cover.
    ///
    /// Waits for the sheet dismissal to complete before presenting,
    /// ensuring a safe transition between modal types.
    /// Middleware can cancel the sheet dismissal by returning `false`.
    /// - Parameter cover: The cover route to present.
    public func dismissSheetThenPresentFull(_ cover: KVFullCoverRoute) {
        enqueue { [weak self] in
            guard let self else { return }
            if let current = self.sheet {
                guard await self.applyDismissMiddlewares(sheet: current, fullCover: nil) else { return }
                self.sheet = nil
                await self.awaitSheetDismissal()
            }
            self.fullCover = cover
        }
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

    /// Build a view for a sheet route.
    func buildCustomSheet(for id: UUID) -> AnyView {
        customSheetBuilders[id]?() ?? AnyView(EmptyView())
    }

    /// Build a view for a full cover route.
    func buildCustomFullCover(for id: UUID) -> AnyView {
        customFullCoverBuilders[id]?() ?? AnyView(EmptyView())
    }
}

// MARK: - ================================
// MARK: Dismiss Completion Handling (Internal)
// MARK: ================================

extension KVAppRouter {

    /// Called by ``KVRouterHost`` after a sheet dismissal animation completes
    /// (programmatic or swipe-down). Drops every custom sheet builder except the
    /// one backing a sheet that is currently presented (sheet-replace case),
    /// and resumes any operation waiting on the dismissal (sheet → cover transitions).
    func sheetDidDismiss() {
        var activeID: UUID?
        if case let .customSheet(id)? = sheet { activeID = id }
        customSheetBuilders = customSheetBuilders.filter { $0.key == activeID }

        let waiters = sheetDismissWaiters
        sheetDismissWaiters = [:]
        waiters.values.forEach { $0.resume() }
    }

    /// Called by ``KVRouterHost`` after a full screen cover dismissal completes.
    /// Drops every custom cover builder except the currently presented one.
    func fullCoverDidDismiss() {
        var activeID: UUID?
        if case let .customFullCover(id)? = fullCover { activeID = id }
        customFullCoverBuilders = customFullCoverBuilders.filter { $0.key == activeID }
    }

    /// Suspend until the sheet dismissal animation completes.
    ///
    /// Resumed by ``sheetDidDismiss()`` when a ``KVRouterHost`` is attached; a
    /// timeout fallback covers routers used without a host so the operation
    /// queue can never stall.
    private func awaitSheetDismissal(timeout: UInt64 = 700_000_000) async {
        let waiterID = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sheetDismissWaiters[waiterID] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeout)
                self?.resumeSheetDismissWaiter(id: waiterID)
            }
        }
    }

    /// Resume a single waiter (timeout path). Safe against double-resume:
    /// the waiter is removed from the registry before resuming.
    private func resumeSheetDismissWaiter(id: UUID) {
        if let continuation = sheetDismissWaiters.removeValue(forKey: id) {
            continuation.resume()
        }
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
        let fromRoute: KVAppRoute? = path.last
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

    /// Apply all middlewares for a dismiss operation.
    /// - Parameters:
    ///   - sheet: The sheet being dismissed (nil if not a sheet dismiss).
    ///   - fullCover: The full cover being dismissed (nil if not a full cover dismiss).
    /// - Returns: `true` if all middlewares allow the dismiss, `false` to cancel.
    private func applyDismissMiddlewares(sheet: KVSheetRoute?, fullCover: KVFullCoverRoute?) async -> Bool {
        for middleware in middlewares {
            let allowed = await middleware.willDismiss(sheet: sheet, fullCover: fullCover)
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

    /// Clean up the top builder if it's a custom view.
    func cleanupTopBuilderIfNeeded() {
        if let last = path.last, case let .customView(id) = last {
            removeCustomView(id)
        }
    }

    /// Clean up builders for routes from a starting index.
    func cleanupBuilders(from startIndex: Int) {
        for i in startIndex..<path.count {
            cleanupBuilder(for: path[i])
        }
    }

    /// Clean up builders no longer in the new path.
    func cleanupOrphanedBuilders(newPath: [KVAppRoute]) {
        let newIDs = Set(newPath.compactMap { route -> UUID? in
            if case let .customView(id) = route { return id }
            return nil
        })
        let currentIDs = Set(path.compactMap { route -> UUID? in
            if case let .customView(id) = route { return id }
            return nil
        })
        currentIDs.subtracting(newIDs).forEach { removeCustomView($0) }
    }
}
