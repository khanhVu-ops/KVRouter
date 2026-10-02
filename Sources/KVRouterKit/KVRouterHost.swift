import SwiftUI
import SwiftUIIntrospect

/// Root host that binds ``KVAppRouter`` to one stable `NavigationStack`.
public struct KVRouterHost<Root: View>: View {

    /// Default hit region for the back swipe on custom-transition screens: one
    /// standard touch target in from the leading edge.
    public static var defaultInteractivePopEdgeWidth: CGFloat {
        KVInteractiveTransitionController.defaultEdgeWidth
    }

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
    private let interactivePopEdgeWidth: CGFloat

    /// - Parameter interactivePopEnabled: Whether a leading-edge swipe pops.
    ///   Applies to the whole stack and to both engines — the custom one and
    ///   UIKit's own recognizer, which the host owns while it is attached.
    ///   Setting `interactivePopGestureRecognizer.isEnabled` yourself does not
    ///   stick; use this. To deny a pop per screen instead, return `false` from
    ///   a middleware's `willPop(from:to:)`.
    /// - Parameter interactivePopEdgeWidth: How far in from the leading edge a
    ///   back swipe may start, for screens using a **custom** transition — those
    ///   are driven by the router's own recognizer, and this is its hit region.
    ///   Widen it to make the swipe easier to catch, narrow it if it argues with
    ///   content near the edge such as a horizontally scrolling row. Screens on
    ///   `.system` are swiped with UIKit's own recognizer, whose region UIKit
    ///   owns, so this does not apply to them.
    public init(
        router: KVAppRouter,
        ignoreKeyboard: Bool = true,
        defaultTransition: KVNavigationTransition = .system,
        interactivePopEnabled: Bool = true,
        interactivePopEdgeWidth: CGFloat = KVRouterHost.defaultInteractivePopEdgeWidth,
        @ViewBuilder root: () -> Root
    ) {
        self.router = router
        self.ignoreKeyboard = ignoreKeyboard
        self.defaultTransition = defaultTransition
        self.interactivePopEnabled = interactivePopEnabled
        self.interactivePopEdgeWidth = interactivePopEdgeWidth
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
            .task(id: interactivePopEdgeWidth) {
                coordinator.interactivePopEdgeWidth = interactivePopEdgeWidth
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
            // A range, not a list: NavigationStack is backed by the same
            // UINavigationController selector on every release since 16, and a
            // list silently stops matching on the first OS it does not name —
            // on iOS 27 with `.v16, .v17, .v18, .v26` the router never attached.
            on: .iOS(.v16...),
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
    @Environment(\.dismiss) private var dismiss

    @ViewBuilder
    var body: some View {
        if #available(iOS 18.0, *),
           let nativeSourceID = coordinator.nativeZoomSourceID(for: entry),
           case .zoom = transition.kind {
            destination
                .navigationTransition(
                    .zoom(sourceID: nativeSourceID, in: namespace)
                )
                .background {
                    if !transition.allowsInteractiveDismiss {
                        KVZoomDismissGestureBlocker()
                    }
                }
                .onAppear {
                    coordinator.registerNativeZoomDismiss(dismiss, for: entry)
                }
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

/// Switches off the dismissal gestures a native zoom installs on its destination —
/// ``KVNavigationTransition/interactiveDismissDisabled(_:)``.
///
/// SwiftUI's `.navigationTransition(.zoom)` has no way to turn them off, and UIKit's
/// (`UIZoomTransitionOptions.interactiveDismissShouldBegin`) belongs to a transition SwiftUI
/// builds itself. UIKit puts three recognizers on the destination's hosting view, named
/// `com.apple.UIKit.ZoomInteractiveDismiss{LeadingEdgePan,SwipeDown,Pinch}` (iOS 26.2): this
/// probe walks up from inside the screen and disables those. Names are matched by prefix and a
/// miss does nothing — a renamed recognizer leaves the zoom interactive, not broken.
private struct KVZoomDismissGestureBlocker: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: Probe, context: Context) {
        uiView.disableZoomDismissal()
    }

    final class Probe: UIView {
        static let namePrefix = "com.apple.UIKit.ZoomInteractiveDismiss"

        override func didMoveToWindow() {
            super.didMoveToWindow()
            disableZoomDismissal()
            // UIKit installs the recognizers as the push transition sets up, which can be
            // after this view reaches the window.
            DispatchQueue.main.async { [weak self] in self?.disableZoomDismissal() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            disableZoomDismissal()
        }

        func disableZoomDismissal() {
            var view: UIView? = superview
            while let current = view {
                for gesture in current.gestureRecognizers ?? []
                where gesture.isEnabled && (gesture.name?.hasPrefix(Self.namePrefix) ?? false) {
                    gesture.isEnabled = false
                }
                view = current.superview
            }
        }
    }
}
