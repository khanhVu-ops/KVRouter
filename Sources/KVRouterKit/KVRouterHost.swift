import SwiftUI
import SwiftUIIntrospect

/// Root host that binds ``KVAppRouter`` to one stable `NavigationStack`.
public struct KVRouterHost<Root: View>: View {
    @ObservedObject private var router: KVAppRouter
    @StateObject private var coordinator: KVTransitionCoordinator
    @StateObject private var sourceRegistry: KVTransitionSourceRegistry
    @Namespace private var transitionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.kvRouteRegistry) private var routeRegistry

    private let root: Root
    private let ignoreKeyboard: Bool
    private let defaultTransition: KVNavigationTransition
    private let interactivePopEnabled: Bool

    /// - Parameter interactivePopEnabled: Whether a leading-edge swipe pops.
    ///   Applies to the whole stack and to both engines — the custom one and
    ///   UIKit's own recognizer, which the host owns while it is attached.
    ///   Setting `interactivePopGestureRecognizer.isEnabled` yourself does not
    ///   stick; use this. To deny a pop per screen instead, return `false` from
    ///   a middleware's `willPop(from:to:)`.
    public init(
        router: KVAppRouter,
        ignoreKeyboard: Bool = true,
        defaultTransition: KVNavigationTransition = .system,
        interactivePopEnabled: Bool = true,
        @ViewBuilder root: () -> Root
    ) {
        self.router = router
        self.ignoreKeyboard = ignoreKeyboard
        self.defaultTransition = defaultTransition
        self.interactivePopEnabled = interactivePopEnabled
        self.root = root()
        // Seeded here as well as pushed in `body`: the introspect callback can
        // attach before the first `task` runs, and an app that opted out should
        // never see a frame where the gesture is live.
        _coordinator = StateObject(
            wrappedValue: KVTransitionCoordinator(
                defaultTransition: defaultTransition,
                interactivePopEnabled: interactivePopEnabled
            )
        )
        _sourceRegistry = StateObject(
            wrappedValue: KVTransitionSourceRegistry()
        )
    }

    public var body: some View {
        navigationStack
            .if(ignoreKeyboard) { view in
                view.ignoresSafeArea(.keyboard)
            }
            // Keyed on the router's identity, not `onAppear`: an app that
            // swaps routers (logout, a new DI scope) without tearing down the
            // host would otherwise leave the coordinator driving the dead one.
            .task(id: ObjectIdentifier(router)) {
                coordinator.sourceRegistry = sourceRegistry
                coordinator.reduceMotion = reduceMotion
                coordinator.router = router
                router.transitionDriver = coordinator
            }
            .onDisappear {
                // Deliberately not `coordinator.detach()`. A TabView switch fires
                // onDisappear without destroying the host, and tearing down the
                // bridge there dropped custom transitions until the tab came
                // back. Only settle what is mid-flight; `attach(to:)` is
                // idempotent, so reappearing needs no repair.
                coordinator.completePendingTransition(cancelled: true)
            }
            // Keyed on the registry's identity rather than folded into the task
            // above: `.kvRoutes` may sit anywhere above the host, so the value
            // can arrive — or be swapped for a new one — after the router is
            // already wired.
            .task(id: routeRegistry.map(ObjectIdentifier.init)) {
                router.routeRegistry = routeRegistry
            }
            .task(id: reduceMotion) {
                coordinator.reduceMotion = reduceMotion
            }
            // The `StateObject` seed only covers the first host; this is what
            // makes the flag bindable to state afterwards.
            .task(id: interactivePopEnabled) {
                coordinator.interactivePopEnabled = interactivePopEnabled
            }
            .task(id: scenePhase) {
                guard scenePhase != .active else { return }
                coordinator.completePendingTransition(cancelled: true)
            }
            .environment(\.kvTransitionNamespace, transitionNamespace)
            .environment(\.kvTransitionSourceRegistry, sourceRegistry)
            .appRouter(router)
    }

    private var navigationStack: some View {
        NavigationStack(path: pathBinding) {
            KVRouterRootDestinations(
                router: router,
                coordinator: coordinator,
                defaultTransition: defaultTransition,
                namespace: transitionNamespace,
                root: root
            )
        }
        .introspect(
            .navigationStack,
            on: .iOS(.v16, .v17, .v18, .v26),
            scope: [.receiver, .ancestor]
        ) { navigationController in
            coordinator.attach(to: navigationController)
        }
    }

    private var pathBinding: Binding<[KVNavigationEntry]> {
        Binding(
            get: { router.navigationEntries },
            set: { router.navigationEntries = $0 }
        )
    }

}

/// Not an `@ObservedObject` on purpose: the destination map is a pure function
/// of the entry SwiftUI hands back, so observing the router here would rebuild
/// every live destination on any unrelated router change (e.g. a sheet).
private struct KVRouterRootDestinations<Root: View>: View {
    let router: KVAppRouter
    let coordinator: KVTransitionCoordinator
    let defaultTransition: KVNavigationTransition
    let namespace: Namespace.ID
    let root: Root

    var body: some View {
        root.navigationDestination(for: KVNavigationEntry.self) { entry in
            KVRouterDestinationContent(
                router: router,
                coordinator: coordinator,
                entry: entry,
                transition: router.transitionOverride(for: entry)
                    ?? defaultTransition,
                namespace: namespace
            )
        }
    }
}

private struct KVRouterDestinationContent: View {
    let router: KVAppRouter
    let coordinator: KVTransitionCoordinator
    let entry: KVNavigationEntry
    let transition: KVNavigationTransition
    let namespace: Namespace.ID

    @Environment(\.kvRouteRegistry) private var registry

    @ViewBuilder
    var body: some View {
        if #available(iOS 18.0, *),
           coordinator.usesNativeZoom(for: entry),
           case .zoom(let sourceID) = transition.kind {
            destination
                .navigationTransition(
                    .zoom(sourceID: sourceID.anyHashable, in: namespace)
                )
        } else {
            destination
        }
    }

    /// Dynamic screens carry their builder in the router; everything else comes
    /// from the registry the composition root declared.
    @ViewBuilder
    private var destination: some View {
        if let dynamic = entry.route.unwrap(KVDynamicViewRoute.self) {
            router.dynamicView(for: dynamic) ?? AnyView(EmptyView())
        } else if let view = registry?.view(for: entry.route.base) {
            view
        } else {
            // An unregistered route is a wiring mistake, not a runtime state to
            // absorb: crash in debug rather than render a blank screen that
            // leaves nothing to diagnose.
            let _ = assertionFailure(
                """
                No destination registered for \(type(of: entry.route.base)). \
                Register it with .kvRoutes { $0.register(...) } on KVRouterHost.
                """
            )
            EmptyView()
        }
    }
}

extension View {
    @ViewBuilder
    func `if`<Transform: View>(
        _ condition: Bool,
        transform: (Self) -> Transform
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
