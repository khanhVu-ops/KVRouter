# KVRouter

Clean, performant, and ergonomic router for SwiftUI — iOS 16+.

- ✅ Type-safe push navigation on top of `NavigationStack`
- ✅ `@MainActor`-isolated with a FIFO operation queue — rapid navigation calls
  keep their order even when async middleware takes varying time per route
- ✅ Dynamic views: `pushView { }`, `presentSheet { }`, `presentFullCover { }`
- ✅ Sheet & full screen cover presentation — sheet → cover transitions wait for
  the actual dismissal to complete (no hardcoded animation delays)
- ✅ Async middleware chain (auth guards, logging, redirects, interstitial ads, …)
- ✅ Deep link handling via `onOpenURL`
- ✅ Automatic cleanup of dynamic view builders (no leaks on swipe-back / swipe-down)
- ✅ State restoration support via `restorePath(_:)`

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

## State Restoration

`KVAppRoute` is `Codable`, so the path can be persisted. When restoring, use
`restorePath(_:)` instead of `setPath(_:)` — it drops `.customView` routes,
whose view builders live in memory only and cannot be re-created from disk:

```swift
let decoded = try JSONDecoder().decode([KVAppRoute].self, from: data)
router.restorePath(decoded)
```

## Threading

`KVAppRouter` is `@MainActor`. Call it from views and other main-actor code
directly; from background code, hop first: `await MainActor.run { router.push(...) }`.

## API Overview

| Operation | Methods |
|---|---|
| Push | `push(_:)`, `pushView(_:)`, `replaceTop(with:)`, `replaceTopWithView(_:)`, `setPath(_:)` |
| Pop | `pop()`, `pop(count:)`, `popTo(_:)`, `popTo(where:)`, `popToRoot()` |
| Sheet | `present(_:)`, `presentSheet(_:)`, `dismissSheet()`, `dismissSheet(afterDismiss:)` |
| Full cover | `presentFull(_:)`, `presentFullCover(_:)`, `dismissFull()`, `dismissSheetThenPresentFull(_:)` |
| Deep link | `handle(url:)` |

## Requirements

- iOS 16.0+
- Swift 5.9+

## License

MIT
