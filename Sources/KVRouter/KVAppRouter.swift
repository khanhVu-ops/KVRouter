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
import Combine

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
/// - Note: Not `@MainActor`-isolated so ``EnvironmentValues/router`` can supply a default without actor violations.
///   Navigation and modal state mutations are scheduled with `Task { @MainActor in … }` so `@Published` updates stay on the main thread.
public final class KVAppRouter: ObservableObject {

    // MARK: - Published State

    /// Navigation stack path for push navigation.
    @Published public var path: [KVAppRoute] = []

    /// Current sheet route (nil = no sheet presented).
    @Published public var sheet: KVSheetRoute? = nil

    /// Current full screen cover route (nil = no cover presented).
    @Published public var fullCover: KVFullCoverRoute? = nil

    /// Middleware chain for route interception.
    private let middlewares: [KVRouteMiddleware]

    /// Host app: return a view for ``KVAppRoute/appFeature(_:)`` ids (e.g. `"profile"`). `nil` → ``EmptyView`` in ``buildView(for:)``.
    public var appFeatureViewBuilder: ((String) -> AnyView?)?

    /// Host app: return a view for ``KVAppRoute/deepLink(_:)`` payloads. `nil` → ``EmptyView``.
    public var deepLinkViewBuilder: ((String) -> AnyView?)?

    // MARK: - View Builder Registries

    /// Registry for custom pushed views (keyed by UUID).
    private var customBuilders: [UUID: () -> AnyView] = [:]

    /// Registry for custom sheet views.
    private var customSheetBuilders: [UUID: () -> AnyView] = [:]

    /// Registry for custom full cover views.
    private var customFullCoverBuilders: [UUID: () -> AnyView] = [:]

    // MARK: - Initialization

    /// Creates a new router instance.
    /// - Parameter middlewares: Route middlewares (auth guards, loggers, interstitial ads, etc.)
    public init(middlewares: [KVRouteMiddleware] = []) {
        self.middlewares = middlewares
        setupPathObserver()
    }

    // MARK: - Path Change Observation

    /// Previous path for detecting system-initiated pops
    private var previousPath: [KVAppRoute] = []

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    /// Flag to distinguish router-controlled pops from system-initiated pops
    private var isRouterControlledPop = false

    /// Setup observer for path changes to detect system-initiated pops
    /// (swipe-back, @Environment(\.dismiss)) and run middleware as side-effects.
    private func setupPathObserver() {
        $path
            .dropFirst() // Skip initial value
            .sink { [weak self] newPath in
                guard let self = self else { return }
                self.handlePathChange(from: self.previousPath, to: newPath)
                self.previousPath = newPath
            }
            .store(in: &cancellables)
    }

    /// Handle system-initiated path changes and run middleware as side-effects.
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
// MARK: Push Navigation
// MARK: ================================

extension KVAppRouter {

    /// Push a typed route onto the navigation stack.
    /// - Parameter route: The route to navigate to.
    public func push(_ route: KVAppRoute) {
        Task { @MainActor in
            guard let finalRoute = await applyMiddlewares(to: route) else { return }
            path.append(finalRoute)
        }
    }

    /// Push a dynamically built view onto the navigation stack.
    ///
    /// The view is lazily built when the navigation occurs.
    /// - Parameter build: Closure that builds the view.
    public func pushView<V: View>(_ build: @escaping () -> V) {
        let id = UUID()
        Task { @MainActor in
            customBuilders[id] = { AnyView(build()) }
            guard let finalRoute = await applyMiddlewares(to: .customView(id)) else {
                customBuilders[id] = nil
                return
            }
            path.append(finalRoute)
        }
    }

    /// Push an already-constructed view onto the navigation stack.
    ///
    /// The view is captured and built lazily.
    /// - Parameter view: The view to push.
    public func pushView<V: View>(_ view: V) {
        pushView { view }
    }

    /// Replace the top route with a new route.
    /// - Parameter route: The route to replace with.
    public func replaceTop(with route: KVAppRoute) {
        Task { @MainActor in
            guard let finalRoute = await applyMiddlewares(to: route) else { return }
            // Clean up only after middleware approves, so a cancelled
            // navigation doesn't strand the current top view without its builder.
            cleanupTopBuilderIfNeeded()

            if path.isEmpty {
                path = [finalRoute]
            } else {
                path[path.count - 1] = finalRoute
            }
        }
    }

    /// Replace the top route with a dynamically built view.
    /// - Parameter build: Closure that builds the view.
    public func replaceTopWithView<V: View>(_ build: @escaping () -> V) {
        let id = UUID()
        Task { @MainActor in
            customBuilders[id] = { AnyView(build()) }
            guard let finalRoute = await applyMiddlewares(to: .customView(id)) else {
                customBuilders[id] = nil
                return
            }
            // Clean up only after middleware approves (see `replaceTop(with:)`).
            cleanupTopBuilderIfNeeded()
            if path.isEmpty {
                path = [finalRoute]
            } else {
                path[path.count - 1] = finalRoute
            }
        }
    }

    /// Set the entire navigation path.
    ///
    /// Applies middlewares to each route and cleans up orphaned builders.
    /// - Parameter routes: The new path.
    public func setPath(_ routes: [KVAppRoute]) {
        Task { @MainActor in
            var transformed: [KVAppRoute] = []
            for route in routes {
                if let finalRoute = await applyMiddlewares(to: route) {
                    transformed.append(finalRoute)
                }
            }
            cleanupOrphanedBuilders(newPath: transformed)
            path = transformed
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
        Task { @MainActor in
            guard !path.isEmpty else { return }
            let from = path.last
            let to = path.count >= 2 ? path[path.count - 2] : nil
            guard await applyPopMiddlewares(from: from, to: to) else { return }
            isRouterControlledPop = true
            let last = path.removeLast()
            cleanupBuilder(for: last)
        }
    }

    /// Pop to the root of the navigation stack.
    /// Middleware runs for the top route being popped.
    public func popToRoot() {
        Task { @MainActor in
            guard !path.isEmpty else { return }
            let from = path.last
            guard await applyPopMiddlewares(from: from, to: nil) else { return }
            isRouterControlledPop = true
            path.forEach { cleanupBuilder(for: $0) }
            path.removeAll(keepingCapacity: true)
        }
    }

    /// Pop to a specific route in the navigation stack.
    ///
    /// If the route is not found, nothing happens.
    /// Middleware runs for the top route being popped.
    /// - Parameter route: The route to pop to.
    public func popTo(_ route: KVAppRoute) {
        Task { @MainActor in
            guard let index = path.firstIndex(of: route) else { return }
            let from = path.last
            guard await applyPopMiddlewares(from: from, to: route) else { return }
            isRouterControlledPop = true
            cleanupBuilders(from: index + 1)
            path = Array(path.prefix(through: index))
        }
    }

    /// Pop to a route matching a predicate.
    /// Middleware runs for the top route being popped.
    /// - Parameter predicate: Condition to match the route.
    public func popTo(where predicate: @escaping (KVAppRoute) -> Bool) {
        Task { @MainActor in
            guard let index = path.lastIndex(where: predicate) else { return }
            let from = path.last
            let to = path[index]
            guard await applyPopMiddlewares(from: from, to: to) else { return }
            isRouterControlledPop = true
            cleanupBuilders(from: index + 1)
            path = Array(path.prefix(through: index))
        }
    }

    /// Pop a specific number of views from the stack.
    /// Middleware runs once for the top route being popped.
    /// - Parameter count: Number of views to pop.
    public func pop(count: Int) {
        Task { @MainActor in
            let removeCount = min(count, path.count)
            guard removeCount > 0 else { return }
            let from = path.last
            let targetIndex = path.count - removeCount
            let to: KVAppRoute? = targetIndex > 0 ? path[targetIndex - 1] : nil
            guard await applyPopMiddlewares(from: from, to: to) else { return }
            isRouterControlledPop = true
            for _ in 0..<removeCount {
                guard let last = path.popLast() else { break }
                cleanupBuilder(for: last)
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
        Task { @MainActor in
            self.sheet = sheet
        }
    }

    /// Present a dynamically built view as a sheet.
    /// - Parameter build: Closure that builds the sheet content.
    public func presentSheet<V: View>(_ build: @escaping () -> V) {
        let id = UUID()
        Task { @MainActor in
            customSheetBuilders[id] = { AnyView(build()) }
            sheet = .customSheet(id)
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
        Task { @MainActor in
            guard let current = sheet else { return }
            guard await applyDismissMiddlewares(sheet: current, fullCover: nil) else { return }
            sheet = nil
        }
    }

    /// Dismiss the current sheet and execute a callback.
    /// Middleware can cancel this operation by returning `false`;
    /// the callback only runs when the dismissal actually happens.
    /// - Parameter action: Callback to execute after dismissal.
    public func dismissSheet(afterDismiss action: @escaping () -> Void) {
        Task { @MainActor in
            guard let current = sheet else { return }
            guard await applyDismissMiddlewares(sheet: current, fullCover: nil) else { return }
            sheet = nil
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
        Task { @MainActor in
            self.fullCover = cover
        }
    }

    /// Present a dynamically built view as a full screen cover.
    ///
    /// If a sheet is currently presented, it will be dismissed first.
    /// - Parameter build: Closure that builds the cover content.
    public func presentFullCover<V: View>(_ build: @escaping () -> V) {
        Task { @MainActor in
            if sheet != nil {
                sheet = nil
                // Delay to allow sheet dismissal animation
                try? await Task.sleep(nanoseconds: 350_000_000) // 0.35s
            }
            let id = UUID()
            customFullCoverBuilders[id] = { AnyView(build()) }
            fullCover = .customFullCover(id)
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
        Task { @MainActor in
            guard let current = fullCover else { return }
            guard await applyDismissMiddlewares(sheet: nil, fullCover: current) else { return }
            fullCover = nil
        }
    }

    /// Dismiss sheet and then present a full screen cover.
    ///
    /// Ensures safe transition between modal types.
    /// - Parameter cover: The cover route to present.
    public func dismissSheetThenPresentFull(_ cover: KVFullCoverRoute) {
        dismissSheet { [weak self] in
            Task { @MainActor in
                self?.presentFull(cover)
            }
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
    /// one backing a sheet that is currently presented (sheet-replace case).
    func sheetDidDismiss() {
        var activeID: UUID?
        if case let .customSheet(id)? = sheet { activeID = id }
        customSheetBuilders = customSheetBuilders.filter { $0.key == activeID }
    }

    /// Called by ``KVRouterHost`` after a full screen cover dismissal completes.
    /// Drops every custom cover builder except the currently presented one.
    func fullCoverDidDismiss() {
        var activeID: UUID?
        if case let .customFullCover(id)? = fullCover { activeID = id }
        customFullCoverBuilders = customFullCoverBuilders.filter { $0.key == activeID }
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

    /// Clean up builder for a specific route if it's a custom view.
    func cleanupBuilder(for route: KVAppRoute) {
        if case let .customView(id) = route {
            customBuilders[id] = nil
        }
    }

    /// Clean up the top builder if it's a custom view.
    func cleanupTopBuilderIfNeeded() {
        if let last = path.last, case let .customView(id) = last {
            customBuilders[id] = nil
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
        currentIDs.subtracting(newIDs).forEach { customBuilders[$0] = nil }
    }
}
