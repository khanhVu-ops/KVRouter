# KVRouter

Clean, performant, and ergonomic router for SwiftUI — iOS 16+, Swift 6.

- ✅ Type-safe push navigation on top of `NavigationStack`
- ✅ **Observation-ready**: on iOS 17+ the router behaves like an `@Observable`
  class (fine-grained, per-property tracking); on iOS 16 it falls back to
  `ObservableObject` — same API, checked at runtime with `#available`
- ✅ `@MainActor`-isolated with a FIFO operation queue — rapid navigation calls
  keep their order even when async middleware takes varying time per route
- ✅ Compiles in Swift 6 language mode (swift-tools 6.2, strict concurrency)
- ✅ Dynamic views: `pushView { }`, `presentSheet { }`, `presentFullCover { }`
- ✅ Pop back to a **specific screen**: `popTo(tag:)`, `popTo(DetailView.self)`,
  `popTo(.appFeature("profile"))`, `popTo(where:)`
- ✅ Sheet & full screen cover presentation — sheet → cover transitions wait for
  the actual dismissal to complete (no hardcoded animation delays)
- ✅ Async middleware chain (auth guards, logging, redirects, interstitial ads, …)
- ✅ Deep link handling via `onOpenURL`
- ✅ Automatic cleanup of dynamic view builders (no leaks on swipe-back / swipe-down)
- ✅ State restoration support via `restorePath(_:)`

## Example App

Open `KVRouterExample/KVRouterExample.xcodeproj` for a runnable demo covering
typed routes, dynamic pushes, FIFO ordering, sheets, full covers, safe
sheet → cover transitions, an auth-guard middleware, and deep links.

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/khanhVu-ops/KVRouter.git", from: "1.0.0")
]
```

Or in Xcode: **File ▸ Add Package Dependencies…** and paste the repo URL.

## Quick Start

### 1. Set up the host

```swift
import KVRouter

@main
struct MyApp: App {
    @StateObject private var router = KVAppRouter(middlewares: [KVLoggingMiddleware()])

    var body: some Scene {
        WindowGroup {
            KVRouterHost(router: router) {
                HomeView()
            }
        }
    }
}
```

### 2. Navigate from any view

```swift
struct HomeView: View {
    @Environment(\.router) private var router

    var body: some View {
        VStack {
            Button("Push a dynamic view") {
                router.pushView { DetailView(id: 42) }
            }
            Button("Present a sheet") {
                router.presentSheet { SettingsView() }
            }
            Button("Present a full screen cover") {
                router.presentFullCover { OnboardingView() }
            }
            Button("Back") { router.pop() }
            Button("Back to root") { router.popToRoot() }
        }
    }
}
```

### 3. Typed routes (optional)

Map stable feature ids to screens in your app target:

```swift
router.appFeatureViewBuilder = { id in
    switch id {
    case "profile": return AnyView(ProfileView())
    case "settings": return AnyView(SettingsView())
    default: return nil
    }
}

// Then navigate with:
router.push(.appFeature("profile"))
```

## Middleware

Middleware can transform, redirect, or cancel navigation:

```swift
struct AuthMiddleware: KVRouteMiddleware {
    func willNavigate(from: KVAppRoute?, to: KVAppRoute) async -> KVAppRoute? {
        if case .appFeature("profile") = to, !Session.isLoggedIn {
            return .appFeature("login") // redirect
        }
        return to
    }
}

let router = KVAppRouter(middlewares: [AuthMiddleware(), KVLoggingMiddleware()])
```

`willPop(from:to:)` and `willDismiss(sheet:fullCover:)` can return `false` to block
pops and modal dismissals (system swipe gestures cannot be cancelled — middleware
runs as a side-effect for those).

## Deep Links

```swift
router.deepLinkViewBuilder = { payload in
    // payload example: "profile/123?ref=home"
    guard payload.hasPrefix("profile/") else { return nil }
    let id = payload.dropFirst("profile/".count)
    return AnyView(ProfileView(id: String(id)))
}
```

URLs arriving via `onOpenURL` are handled automatically by `KVRouterHost`.
Unknown payloads are ignored — no navigation happens.

## Pop to a Specific Screen

Typed routes can be targeted directly:

```swift
router.popTo(.appFeature("profile"))
router.popTo(where: { route in /* custom condition */ })
```

Dynamic views (`pushView { }`) have an opaque `.customView(UUID)` route, so
KVRouter offers two ways to target them:

**By tag** — name the screen when pushing:

```swift
router.pushView(tag: "checkout") { CheckoutView(cart: cart) }
// … several screens later:
router.popTo(tag: "checkout")
// Also matches typed routes: popTo(tag: "profile") finds .appFeature("profile")
```

**By view type** — zero configuration, the router records the concrete type at
push time:

```swift
router.pushView { DetailView(id: 1) }
router.pushView { SettingsView() }
router.pushView { DetailView(id: 2) }

router.popTo(DetailView.self) // → DetailView(id: 2), the nearest one
```

Both search from the top down and **exclude the current screen** — calling
`popTo(DetailView.self)` from a `DetailView` pops back to the *previous*
`DetailView` instance. If nothing below matches, nothing happens. `willPop`
middleware runs and can cancel, like every other pop.

## State Restoration

`KVAppRoute` is `Codable`, so the path can be persisted. When restoring, use
`restorePath(_:)` instead of `setPath(_:)` — it drops `.customView` routes,
whose view builders live in memory only and cannot be re-created from disk:

```swift
let decoded = try JSONDecoder().decode([KVAppRoute].self, from: data)
router.restorePath(decoded)
```

## Observation (iOS 17+) vs ObservableObject (iOS 16)

`KVAppRouter` supports both observation systems at once, selected at runtime:

- **iOS 17+** — the router conforms to `Observable` and reports property
  access/mutation through an `ObservationRegistrar`, exactly like the
  `@Observable` macro. Views that read `router.path` / `router.sheet` /
  `router.fullCover` directly (e.g. via `@Environment(\.router)`) re-render
  only when the property they actually read changes.
- **iOS 16** — falls back to `ObservableObject` (`objectWillChange`), so
  `@StateObject` / `@ObservedObject` keep working.

No configuration needed — the check is `if #available(iOS 17.0, *)` inside.

## Threading & Swift 6

`KVAppRouter` is `@MainActor` and the package compiles in Swift 6 language
mode. Call the router from views and other main-actor code directly; from
background code, hop first: `await MainActor.run { router.push(...) }`.
`KVRouteMiddleware` is `@MainActor` too — offload heavy work inside a
middleware with a background `Task` if needed.

## Requirements (package)

- iOS 16.0+ (Observation fast path on iOS 17+)
- Swift 6.2 toolchain (Xcode 26+) to build; Swift 6 language mode

## API Overview

| Operation | Methods |
|---|---|
| Push | `push(_:)`, `pushView(tag:_:)`, `replaceTop(with:)`, `replaceTopWithView(tag:_:)`, `setPath(_:)` |
| Pop | `pop()`, `pop(count:)`, `popTo(_:)`, `popTo(tag:)`, `popTo(SomeView.self)`, `popTo(where:)`, `popToRoot()` |
| Sheet | `present(_:)`, `presentSheet(_:)`, `dismissSheet()`, `dismissSheet(afterDismiss:)` |
| Full cover | `presentFull(_:)`, `presentFullCover(_:)`, `dismissFull()`, `dismissSheetThenPresentFull(_:)` |
| Deep link | `handle(url:)` |

## License

MIT
