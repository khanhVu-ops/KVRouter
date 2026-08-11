# KVRouterKit

An ergonomic, transition-aware SwiftUI router for iOS 16+ and Swift 6.

- Type-safe `NavigationStack` routing and dynamic `pushView` destinations
- Selectable push/pop transitions with automatic reverse motion
- Native hero zoom on iOS 18+ and a live-view fallback on iOS 16-17
- Interactive leading-edge pop for custom transition styles
- GPU-friendly value-based custom transition DSL
- FIFO navigation queue, async middleware, deep links and state restoration
- Sheets and full-screen covers with safe presentation sequencing
- Reduce Motion, interruption and live hierarchy cleanup

## Example App

Open `KVRouterKitExample/KVRouterKitExample.xcodeproj` to run the transition
gallery and the routing, middleware, modal and deep-link demos.

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

## Migration From KVRouter 1.x

The package, product, target and import name are now `KVRouterKit`:

```swift
import KVRouterKit
```

Public router symbols remain unchanged, including `KVAppRouter`,
`KVRouterHost`, `KVAppRoute` and the middleware protocols. Existing calls that
do not specify a transition keep their original system-navigation behavior.

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
        }
    }
}
```

Use the environment router from any hosted view:

```swift
struct HomeView: View {
    @Environment(\.router) private var router

    var body: some View {
        VStack {
            Button("Open detail") {
                router.pushView {
                    DetailView(id: 42)
                }
            }

            Button("Open with depth") {
                router.pushView(transition: .depth) {
                    DetailView(id: 43)
                }
            }

            Button("Present settings") {
                router.presentSheet { SettingsView() }
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

router.push(.appFeature("profile"), transition: .fade)

router.pushView(transition: .depth) {
    DetailView(id: 42)
}

router.replaceTop(with: .appFeature("settings"))
```

The transition stored with the top entry is automatically reversed by a
single-screen `pop()`. Replace and bulk path changes stay system-owned so the
navigation hierarchy remains predictable.

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
}
.buttonStyle(.plain)
.kvTransitionSource(id: item.id)
```

On iOS 18+, KVRouterKit packages SwiftUI's native
`matchedTransitionSource(id:in:)` and `.navigationTransition(.zoom)` APIs. On
iOS 16-17, the same call site transforms the live navigation views. If a source
is no longer visible, navigation falls back to `.scaleAndFade` instead of
blocking the queue.

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

Map stable feature IDs to views in the app target:

```swift
router.appFeatureViewBuilder = { id in
    switch id {
    case "profile": return AnyView(ProfileView())
    case "settings": return AnyView(SettingsView())
    default: return nil
    }
}

router.push(.appFeature("profile"), transition: .sharedAxis())
```

## Pop Targets

```swift
router.pop()
router.pop(count: 2)
router.popToRoot()
router.popTo(.appFeature("profile"))
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
        from: KVAppRoute?,
        to: KVAppRoute
    ) async -> KVAppRoute? {
        if case .appFeature("premium") = to, !Session.isLoggedIn {
            return .appFeature("login")
        }
        return to
    }
}
```

`willPop(from:to:)` and `willDismiss(sheet:fullCover:)` return `false` to deny
their corresponding router operation.

## Deep Links

```swift
router.deepLinkViewBuilder = { payload in
    guard payload.hasPrefix("profile/") else { return nil }
    let id = String(payload.dropFirst("profile/".count))
    return AnyView(ProfileView(id: id))
}
```

URLs delivered through `onOpenURL` are handled automatically by
`KVRouterHost`. Unknown payloads are ignored.

## State Restoration

`KVAppRoute` is `Codable`. Restore persisted paths with `restorePath(_:)`:

```swift
let path = try JSONDecoder().decode([KVAppRoute].self, from: data)
router.restorePath(path)
```

Dynamic `.customView` routes are in-memory only, so restoration drops custom
views and uses the host default transition for restored typed routes.

## Observation and Concurrency

- iOS 17+: `KVAppRouter` participates in fine-grained Observation tracking.
- iOS 16: the same API falls back to `ObservableObject`.
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
| Path changes | `replaceTop`, `setPath`, `restorePath` |
| Pop | `pop()`, `pop(count:)`, `popTo(_:)`, `popTo(tag:)`, `popTo(SomeView.self)`, `popToRoot()` |
| Hero | `.zoom(sourceID:)`, `.kvTransitionSource(id:)` |
| Modal | `presentSheet`, `dismissSheet`, `presentFullCover`, `dismissFull` |
| Deep link | `handle(url:)` |

## License

MIT
