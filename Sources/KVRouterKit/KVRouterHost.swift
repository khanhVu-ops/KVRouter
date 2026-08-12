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

    private let root: Root
    private let ignoreKeyboard: Bool
    private let defaultTransition: KVNavigationTransition

    public init(
        router: KVAppRouter,
        ignoreKeyboard: Bool = true,
        defaultTransition: KVNavigationTransition = .system,
        @ViewBuilder root: () -> Root
    ) {
        self.router = router
        self.ignoreKeyboard = ignoreKeyboard
        self.defaultTransition = defaultTransition
        self.root = root()
        _coordinator = StateObject(
            wrappedValue: KVTransitionCoordinator(
                defaultTransition: defaultTransition
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
            .sheet(
                item: sheetBinding,
                onDismiss: { router.sheetDidDismiss() }
            ) { sheet in
                KVRouterSheetContent(router: router, sheet: sheet)
            }
            .fullScreenCover(
                item: fullCoverBinding,
                onDismiss: { router.fullCoverDidDismiss() }
            ) { cover in
                KVRouterFullCoverContent(router: router, cover: cover)
            }
            .onOpenURL { router.handle(url: $0) }
            .onAppear {
                coordinator.sourceRegistry = sourceRegistry
                coordinator.reduceMotion = reduceMotion
                coordinator.router = router
                router.transitionDriver = coordinator
            }
            .onDisappear {
                coordinator.detach()
                if let driver = router.transitionDriver,
                   driver === coordinator {
                    router.transitionDriver = nil
                }
                coordinator.sourceRegistry = nil
                coordinator.router = nil
            }
            .task(id: reduceMotion) {
                coordinator.reduceMotion = reduceMotion
            }
            .task(id: scenePhase) {
                guard scenePhase != .active else { return }
                coordinator.completePendingTransition(cancelled: true)
            }
            .task(id: liveEntryIDs) {
                coordinator.retainEntryMetadata(for: Set(liveEntryIDs))
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

    private var liveEntryIDs: [UUID] {
        router.navigationEntries.map(\.id)
    }

    private var pathBinding: Binding<[KVNavigationEntry]> {
        Binding(
            get: { router.navigationEntries },
            set: { router.navigationEntries = $0 }
        )
    }

    private var sheetBinding: Binding<KVSheetRoute?> {
        Binding(
            get: { router.sheet },
            set: { newValue in
                if newValue == nil {
                    Task { @MainActor in router.sheet = nil }
                } else {
                    router.sheet = newValue
                }
            }
        )
    }

    private var fullCoverBinding: Binding<KVFullCoverRoute?> {
        Binding(
            get: { router.fullCover },
            set: { newValue in
                if newValue == nil {
                    Task { @MainActor in router.fullCover = nil }
                } else {
                    router.fullCover = newValue
                }
            }
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

    @ViewBuilder
    var body: some View {
        if #available(iOS 18.0, *),
           coordinator.usesNativeZoom(for: entry),
           case .zoom(let sourceID) = transition.kind {
            router.buildView(for: entry)
                .navigationTransition(
                    .zoom(sourceID: sourceID, in: namespace)
                )
        } else {
            router.buildView(for: entry)
        }
    }
}

private struct KVRouterSheetContent: View {
    let router: KVAppRouter
    let sheet: KVSheetRoute

    var body: some View {
        router.buildSheet(for: sheet)
    }
}

private struct KVRouterFullCoverContent: View {
    let router: KVAppRouter
    let cover: KVFullCoverRoute

    var body: some View {
        router.buildFullCover(for: cover)
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
