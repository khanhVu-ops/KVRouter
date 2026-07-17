//
//  KVRouterHost.swift
//  KVRouter
//
//  Created by Khanh Vu.
//

import SwiftUI

// MARK: - ================================
// MARK: Router Host
// MARK: ================================

/// Root host view that integrates NavigationStack with sheet and full cover presentation.
///
/// **Usage:**
/// ```swift
/// KVRouterHost(router: router) {
///     HomeView()
/// }
/// ```
///
/// **Features:**
/// - Automatic NavigationStack binding to router path
/// - Sheet and full screen cover presentation
/// - Keyboard avoidance disabled by default (configurable)
/// - Router environment injection
public struct KVRouterHost<Root: View>: View {

    // MARK: - Properties

    @ObservedObject private var router: KVAppRouter
    private let root: Root
    private let ignoreKeyboard: Bool

    // MARK: - Initialization

    /// Creates a router host with the given router and root content.
    /// - Parameters:
    ///   - router: The app router instance.
    ///   - ignoreKeyboard: Whether to ignore safe area for keyboard. Default: true.
    ///   - root: The root content view builder.
    public init(
        router: KVAppRouter,
        ignoreKeyboard: Bool = true,
        @ViewBuilder root: () -> Root
    ) {
        self.router = router
        self.ignoreKeyboard = ignoreKeyboard
        self.root = root()
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack(path: pathBinding) {
            KVRouterRootDestinations(router: router, root: root)
        }
        .if(ignoreKeyboard) { view in
            view.ignoresSafeArea(.keyboard)
        }
        .sheet(item: sheetBinding, onDismiss: { router.sheetDidDismiss() }) { sheet in
            KVRouterSheetContent(router: router, sheet: sheet)
        }
        .fullScreenCover(item: fullCoverBinding, onDismiss: { router.fullCoverDidDismiss() }) { cover in
            KVRouterFullCoverContent(router: router, cover: cover)
        }
        .onOpenURL { url in
            router.handle(url: url)
        }
        .appRouter(router)
    }

    // MARK: - Bindings

    /// Explicit bindings avoid `$router.path` / `$router.fullCover` dynamicMember issues with ``ObservedObject`` in strict Swift 6.
    private var pathBinding: Binding<[KVAppRoute]> {
        Binding(
            get: { router.path },
            set: { router.path = $0 }
        )
    }

    /// System-initiated dismissals (swipe down) set the binding to nil.
    /// Deferred to the next run loop to avoid mutating state during a view update;
    /// builder cleanup happens in `onDismiss` after the animation completes.
    private var sheetBinding: Binding<KVSheetRoute?> {
        Binding(
            get: { router.sheet },
            set: { newValue in
                if newValue == nil {
                    DispatchQueue.main.async {
                        router.sheet = nil
                    }
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
                    DispatchQueue.main.async {
                        router.fullCover = nil
                    }
                } else {
                    router.fullCover = newValue
                }
            }
        )
    }
}

// MARK: - Nested views (avoid ObservedObject / dynamicMember issues in generic host bodies)

private struct KVRouterRootDestinations<Root: View>: View {
    @ObservedObject var router: KVAppRouter
    var root: Root

    var body: some View {
        root
            .navigationBarBackButtonHidden(true)
            .navigationDestination(for: KVAppRoute.self) { route in
                router.buildView(for: route)
            }
    }
}

private struct KVRouterSheetContent: View {
    @ObservedObject var router: KVAppRouter
    var sheet: KVSheetRoute

    var body: some View {
        router.buildSheet(for: sheet)
    }
}

private struct KVRouterFullCoverContent: View {
    @ObservedObject var router: KVAppRouter
    var cover: KVFullCoverRoute

    var body: some View {
        router.buildFullCover(for: cover)
    }
}

// MARK: - ================================
// MARK: Conditional View Modifier
// MARK: ================================

public extension View {
    /// Apply a modifier conditionally.
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
