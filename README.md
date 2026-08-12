# KVRouterKit

An ergonomic, transition-aware SwiftUI router for iOS 16+ and Swift 6.

- Type-safe `NavigationStack` routing and dynamic `pushView` destinations
- Selectable push/pop transitions with automatic reverse motion
- Native hero zoom on iOS 18+ and a live-view fallback on iOS 16-17
- Interactive leading-edge pop for custom transition styles
- GPU-friendly value-based custom transition DSL
- FIFO navigation queue, async middleware, deep links and state restoration
- Reduce Motion, interruption and live hierarchy cleanup

## Scope

KVRouterKit manages the **navigation stack**. Modals are not its business: use
SwiftUI's own `.sheet` and `.fullScreenCover`, which already model presentation
declaratively and need nothing from a router.

To chain a cover after a sheet — SwiftUI cannot present one over the other —
drive it from `onDismiss`, which fires once the dismissal actually finishes:

```swift
.sheet(isPresented: $showsSheet) {
    if coverFollowsSheet { coverFollowsSheet = false; showsCover = true }
} content: {
    SettingsSheetView(presentCoverOnDismiss: $coverFollowsSheet)
}
.fullScreenCover(isPresented: $showsCover) { OnboardingCoverView() }
```

## Example App

Open `KVRouterKitExample/KVRouterKitExample.xcodeproj` to run the transition
gallery and the routing, middleware, modal and deep-link demos.
The "Modal" section shows the sheet-then-cover recipe above.

## Installation

Add KVRouterKit with Swift Package Manager:

```swift
dependencies: [
    .package(
        url: "https://github.com/khanhVu-ops/KVRouter.git",
        from: "2.0.0"
    )
]
```

Then add the `KVRouterKit` product to your app target.

See [CHANGELOG.md](CHANGELOG.md) for release history and migration notes.

## Products

The package ships three products: `KVRouterKit` (router plus SwiftUI host),
`KVRouterCore` (route model and the `KVRouting` command port — no SwiftUI or
UIKit), and `KVRouterTesting` (spies, for test targets). A presentation layer
imports only `KVRouterCore`.

## Quick Start

Create one router and install `KVRouterHost` at the root of the app:

```swift
import KVRouterKit
import SwiftUI

@main
struct MyApp: App {
    @StateObject private var router = KVAppRouter(
        middlewares: [KVLoggingMiddleware()]
    )

    var body: some Scene {
        WindowGroup {
            KVRouterHost(
                router: router,
                defaultTransition: .sharedAxis()
            ) {
                HomeView()
            }
            .kvRoutes { routes in
                routes.register(ShopRoute.self) { route in
                    switch route {
                    case .productDetail(let id): ProductDetailView(id: id)
                    case .cart:                  CartView()
                    }
                }
            }
        }
    }
}
```

`.kvRoutes` is where routes meet views. A route type with no registration trips
an assertion in debug builds rather than rendering blank.

Use the environment router from any hosted view:

```swift
struct HomeView: View {
    @Environment(\.router) private var router

    var body: some View {
        VStack {
            Button("Open a typed route") {
                router.push(ShopRoute.productDetail(id: 42))
            }

            Button("Open an ad-hoc screen") {
                router.pushView {
                    DetailView(id: 42)
                }
            }

            Button("Open with depth") {
                router.pushView(transition: .depth) {
                    DetailView(id: 43)
                }
            }
        }
    }
}
```

## Navigation Transitions

Set a host default or override it for one navigation operation:

```swift
KVRouterHost(router: router, defaultTransition: .sharedAxis()) {
    HomeView()
}

router.push(ShopRoute.profile, transition: .fade)

router.pushView(transition: .depth) {
    DetailView(id: 42)
}

router.replaceTop(with: ShopRoute.settings)
```

The transition stored with the top entry is automatically reversed by a
single-screen `pop()`. Bulk path changes are not animated: SwiftUI does not hand
UIKit a single matching stack operation for them.

Replacing the top screen comes in two flavours:

```swift
router.replaceTop(with: SettingsRoute.root)                        // instant
router.replaceTop(with: SettingsRoute.root, transition: .flip3D()) // animated
```

The animated one is built rather than native — UIKit has no replace operation to
drive. It pushes the new screen with the transition, then drops the screen
underneath once the animation finishes, while it is covered.

Two consequences worth knowing:

- **The transition applies to the replace only.** The new screen inherits the pop
  transition of the screen it replaced, so going back from it looks the way going
  back from that screen did — not like the replace animation in reverse.
- **The stack is one entry deeper for the duration.** `stackDepth` reads one
  higher, and a back swipe landing inside that window returns to the replaced
  screen. Use the instant form when that matters more than the motion does.

### Built-In Styles

```swift
.system
.slide(edge: .trailing)
.fade
.scale
.scaleAndFade
.sharedAxis(axis: .horizontal)
.depth
.reveal(origin: .topTrailing)
.flip3D(axis: .vertical)
```

Override the default timing curve on any transition:

```swift
let transition = KVNavigationTransition.depth
    .animation(.spring(response: 0.6, dampingFraction: 0.82))
```

### Hero Zoom

Give the visible source and the pushed transition the same stable ID:

```swift
Button {
    router.pushView(transition: .zoom(sourceID: item.id)) {
        DetailView(item: item)
    }
} label: {
    CardView(item: item)
        .kvTransitionSource(id: item.id)
        .shadow(color: .black.opacity(0.16), radius: 16, y: 10)
}
.buttonStyle(.plain)
```

Apply external effects such as shadows after `kvTransitionSource`. This keeps
them outside the native zoom snapshot and avoids stretched shadow artifacts
during the reverse transition.

On iOS 18+, KVRouterKit packages SwiftUI's native
`matchedTransitionSource(id:in:)` and `.navigationTransition(.zoom)` APIs. On
iOS 16-17, the same call site transforms the live navigation views. If a source
is no longer visible, navigation falls back to `.scaleAndFade` instead of
blocking the queue.

Pass the source's corner radius — SwiftUI's `clipShape` and `cornerRadius` do not
set `layer.cornerRadius`, so it cannot be measured, and leaving it at 0 makes the
transition animate to and from square corners over a rounded source:

```swift
CardView(item: item)
    .clipShape(RoundedRectangle(cornerRadius: 24))
    .kvTransitionSource(id: item.id, cornerRadius: 24)
```

### Custom Transitions

Custom transitions describe only compositor-safe endpoint values. KVRouterKit
compiles them once and lets `UIViewPropertyAnimator` animate the live views:

```swift
let orbit = KVNavigationTransition.custom(
    push: KVTransitionStage(
        incoming: .identity
            .relativeOffset(y: 0.08)
            .scale(0.86)
            .rotation(.degrees(12))
            .opacity(0),
        outgoing: .identity
            .scale(0.97)
            .rotation(.degrees(-3))
            .opacity(0.9)
    ),
    pop: .mirrored,
    animation: .spring(response: 0.55, dampingFraction: 0.78),
    interactiveBack: true
)

router.pushView(transition: orbit) {
    DetailView(id: 44)
}
```

Set `interactiveBack: false` if a custom transform should only support
programmatic pop.

### Platform Support

| Requested style | iOS 16-17 | iOS 18+ |
|---|---|---|
| `.system` | Native system navigation | Native system navigation |
| `.zoom` | Custom live-view hero | Native SwiftUI zoom |
| Other built-ins | KVRouterKit custom engine | KVRouterKit custom engine |
| `.custom` | KVRouterKit custom engine | KVRouterKit custom engine |

Custom styles support interactive pop from the leading screen edge. System
and native zoom transitions retain the system navigation gesture. When Reduce
Motion is enabled, custom motion collapses to a short crossfade; native
transitions defer to SwiftUI.

### Animation Ownership and Performance

KVRouterKit keeps one live `NavigationStack` hierarchy and animates only
single-screen push and pop operations:

- `.system` always remains UIKit/SwiftUI-owned.
- `.zoom` uses Apple's native hero transition on iOS 18+.
- Custom styles use `UIViewPropertyAnimator` with the existing live controller
  views; no navigation-screen snapshots are created.
- Router-driven system and native-zoom operations are scoped so they still
  animate when newer SwiftUI runtimes reconcile the path with
  `animated: false` internally.
- Replace, restoration, bulk stack mutations and navigation controllers not
  managed by KVRouterKit keep their original system behavior.

Because the original view controllers stay in the navigation hierarchy, local
SwiftUI state is preserved when popping back. The compatibility layer performs
only a small policy lookup per navigation mutation and adds no per-frame work.

## Typed Routes

Declare routes wherever the navigation intent lives. They are plain values, so
the module that owns them never imports SwiftUI:

```swift
import KVRouterCore

enum ShopRoute: KVRoute {
    case productDetail(id: Int)
    case cart
}
```

Say what each renders as once, in the composition root:

```swift
KVRouterHost(router: router) { HomeView() }
    .kvRoutes { routes in
        routes.register(ShopRoute.self) { route in
            switch route {
            case .productDetail(let id): ProductDetailView(id: id)
            case .cart:                  CartView()
            }
        }
    }

router.push(ShopRoute.productDetail(id: 42), transition: .sharedAxis())
```

An unregistered route type trips an assertion in debug builds rather than
rendering a blank screen.

## MVVM and Clean Architecture

Inject `any KVRouting` — stack commands only, no SwiftUI — into a ViewModel:

```swift
final class ProductListViewModel {
    private let router: any KVRouting
    init(router: any KVRouting) { self.router = router }

    func didTapProduct(_ id: Int) {
        router.push(ShopRoute.productDetail(id: id))
    }
}
```

Test it against `KVRouterSpy`, which is synchronous and needs no host:

```swift
import KVRouterTesting

let router = KVRouterSpy()
ProductListViewModel(router: router).didTapProduct(42)
#expect(router.operations == [.push(AnyKVRoute(ShopRoute.productDetail(id: 42)))])
```

View code that needs `pushView { }` or a per-navigation transition takes
`any KVViewRouting` instead — the same port plus the view-layer commands.

## Pop Targets

```swift
router.pop()
router.pop(count: 2)
router.popToRoot()
router.popTo(ShopRoute.cart)
router.popTo(tag: "checkout")
router.popTo(DetailView.self)
router.popTo(where: { route in /* custom match */ false })
```

Tag dynamic destinations when they need a stable pop target:

```swift
router.pushView(tag: "checkout", transition: .depth) {
    CheckoutView()
}
```

Searches run from the top down and exclude the current screen. If no destination
matches, the router leaves the stack unchanged.

## Middleware

Middleware can redirect or cancel navigation and can block router-driven pops:

```swift
struct AuthMiddleware: KVRouteMiddleware {
    func willNavigate(
        from: (any KVRoute)?,
        to: any KVRoute
    ) async -> (any KVRoute)? {
        if (to as? ShopRoute) == .premium, !Session.isLoggedIn {
            return ShopRoute.login
        }
        return to
    }
}
```

`willPop(from:to:)` returns `false` to deny the pop.

## Deep Links

URL shapes belong to the app, so parsing is yours — which also makes it a pure
function you can unit-test without a router:

```swift
enum AppDeepLink {
    static func route(for url: URL) -> (any KVRoute)? {
        guard url.host == "product",
              let id = url.pathComponents.filter({ $0 != "/" }).first.flatMap(Int.init)
        else { return nil }
        return ShopRoute.productDetail(id: id)
    }
}

.onOpenURL { url in
    if let route = AppDeepLink.route(for: url) { router.push(route) }
}
```

## State Restoration

Mark the routes you persist as `KVRestorableRoute` (`KVRoute` + `Codable`), then
round-trip the stack through `KVPathCodec`:

```swift
enum ShopRoute: KVRestorableRoute {
    case productDetail(id: Int)
    case cart
}

var codec = KVPathCodec()
codec.register(ShopRoute.self)
codec.register(AuthRoute.self)      // a stack can mix route types

// Saving
try codec.encode(router.routes).write(to: url)

// Restoring
router.setPath(try codec.decode(Data(contentsOf: url)))
```

A stack is a path, not a set: dropping an entry from the middle changes what the
screens below it mean. So anything that cannot be carried across **truncates the
stack at that point** rather than being skipped —

- a route that is not `KVRestorableRoute` (`pushView { }` screens, whose view is
  a closure held in memory),
- a type the reading codec was not told about,
- a payload that no longer decodes after a shape change.

`[Home, Product, Checkout]` with an undecodable `Product` restores as `[Home]`,
never `[Home, Checkout]`. An archive written by an unrecognised format version
throws `KVPathCodecError.unsupportedVersion` instead of quietly restoring
nothing.

## Observation and Concurrency

- iOS 17+: `KVAppRouter` participates in fine-grained Observation tracking.
- iOS 16: the same API falls back to `ObservableObject`.
- The fallback is asymmetric, so prefer sending commands over rendering from
  stack state: `@Environment(\.router)` does not observe an `ObservableObject`,
  so a body reading `stackDepth` updates on iOS 17+ and silently never updates
  on iOS 16. Use `@ObservedObject` if a view genuinely must render from it.
- Router and middleware APIs are `@MainActor` isolated.
- Navigation operations use a FIFO queue, including rapid calls around async
  middleware.

## Requirements

- iOS 16.0+
- Swift 6.2 toolchain / Xcode 26+
- Swift 6 language mode for the package

## API Overview

| Area | Primary APIs |
|---|---|
| Push | `push(_:transition:)`, `pushView(tag:transition:_:)` |
| Path changes | `replaceTop(with:)`, `replaceTop(with:transition:)`, `setPath` |
| Pop | `pop()`, `pop(count:)`, `popTo(_:)`, `popTo(tag:)`, `popTo(SomeView.self)`, `popToRoot()` |
| Hero | `.zoom(sourceID:)`, `.kvTransitionSource(id:)` |
| Routes | `KVRoute`, `.kvRoutes { }`, `KVRouting`, `KVViewRouting` |
| Restoration | `KVRestorableRoute`, `KVPathCodec` |
| Testing | `KVRouterSpy`, `settle()` |

## License

MIT
