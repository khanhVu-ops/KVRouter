# Changelog

All notable changes to KVRouterKit are documented in this file.

## Unreleased — 3.0.0

Not released yet. 3.0 is a clean break: there is no compatibility shim and no
migration guide, because effectively nobody depends on 2.x yet.

### Breaking Changes

- **`KVAppRoute` is gone.** Apps declare their own routes as plain values
  conforming to `KVRoute`, and the composition root maps them to views with
  `.kvRoutes { }`. `appFeatureViewBuilder` and `deepLinkViewBuilder` are removed
  along with it — the closed three-case enum meant "type-safe routing" was in
  practice either `appFeature("some-string")` or a `pushView { }` closure.
- **Modals are no longer the router's business.** `KVSheetRoute`,
  `KVFullCoverRoute`, `sheet`, `fullCover`, every `present*` / `dismiss*` method
  and `KVRouteMiddleware.willDismiss` are removed. Use SwiftUI's own `.sheet`
  and `.fullScreenCover`; see the Scope section of the README for the
  sheet-then-cover recipe.
- **`handle(url:)` and `restorePath` are removed.** Deep links are parsed by the
  app and pushed like any other route.
- `KVRouteMiddleware` now speaks `any KVRoute` instead of `KVAppRoute`.
- `@Environment(\.router)` is typed `any KVViewRouting` rather than
  `KVAppRouter`, and defaults to a placeholder that reports a missing host.
- The public `path` property is replaced by the read-only `routes` snapshot plus
  `stackDepth` and `topRoute`.
- `popTo(tag:)` no longer matches typed routes. Tags come only from `pushView`;
  a typed route is a value, so `popTo(_:)` addresses it directly.

### Added

- `KVRouterCore`: the route model (`KVRoute`, `AnyKVRoute`, `KVRestorableRoute`)
  and the `KVRouting` command port. Foundation only — no SwiftUI, UIKit,
  Introspect or method swizzling — so a presentation layer can depend on it.
- `KVRouterTesting`: `KVRouterSpy`, a synchronous recording router with a
  simulated stack, for testing ViewModels without a host.
- `KVViewRouting`: `KVRouting` plus the view-layer commands (`pushView { }`,
  transition overloads).
- `KVAppRouter.settle()`: await the FIFO queue instead of polling.
- `KVAppRouter.middlewareTimeout`, so a hung middleware cannot wedge navigation.
- `handlePathChange` identifies removed entries by id rather than assuming a
  trailing truncation, which an animated replace violates by design.
- `KVNavigationTransition.pageTurn(edge:)`: a 3D rotation pivoted on a spine
  rather than the centre, so it reads as turning paper rather than flipping a
  card. Built on a new `anchor(_:)` transition primitive, which moves the point
  transforms pivot around -- applied before the animation starts, since moving an
  anchor shifts the layer's position and animating that shift would slide the view.
- `KVPathCodec`: persists and restores a stack of mixed route types, keyed on
  `KVRestorableRoute.restorationID`. Anything that cannot be carried across
  truncates the stack at that point rather than leaving a hole in it.

### Fixed

- A single `isRouterControlledPop` flag decided whether a pop was
  router-driven. It could not describe two pops in flight, and any path change
  that failed to shrink left it stuck, silently swallowing `willPop` for the
  next system pop. Replaced by per-entry bookkeeping.
- A system pop of several screens spawned one detached `Task` per screen,
  outside the FIFO queue, letting their middleware interleave.
- The middleware chain had no watchdog, so one `await` that never returned
  wedged the operation queue for the rest of the process.
- `replaceTop(with:transition:)` recorded the transition but never played it;
  the argument only took effect when that entry was later popped. There is no
  UIKit replace operation to drive -- confirmed by probing a real
  UINavigationController and by watching a deliberately two-second transition not
  play -- so the overload is rebuilt as a push followed by dropping the screen
  underneath once the animation finishes. It animates; the trade is that the
  stack is one entry deeper for the duration. The transition applies to the
  replace only: the new entry inherits the pop transition of the screen it
  replaced, and the drop is applied as a silent stack edit that no animator will
  claim. Both were needed -- storing the replace transition on the new entry made
  it play twice and made going back play it in reverse.
- A zoom transition animated to and from square corners over a rounded source.
  SwiftUI's `clipShape` and `cornerRadius` never reach `layer.cornerRadius`, so
  measuring the layer reported 0; `kvTransitionSource(id:cornerRadius:)` now takes
  the value and passes it to both the registry and the system's
  `matchedTransitionSource` configuration.
- Swipe-to-dismiss on a zoom transition left the source view hidden, holding an
  empty slot in the layout, while a button dismiss was fine. Zoom metadata was
  pruned when the navigation path changed, which for an interactive dismissal is
  when the gesture *commits* -- before its animation ends. The destination then
  re-rendered without `.navigationTransition(.zoom:)` mid-dismissal and SwiftUI
  never un-hid `matchedTransitionSource`. A button pop finished before the
  re-render, which is why only the gesture showed it. Pruning now waits for UIKit
  to report the transition finished.
- Animation forcing on the native-zoom path is push-only. The push needs it
  (SwiftUI hands UIKit `animated: false` and the zoom would not play); the pop
  does not, since SwiftUI drives that dismissal itself.
- Sheet and full-cover view builders leaked on swipe-to-dismiss. Removed with
  the modal layer rather than patched.
- The transition coordinator was wired in `onAppear`, so swapping routers left
  it driving the previous one.
- `onDisappear` tore down the UIKit bridge, so a `TabView` switch dropped custom
  transitions until the tab came back.
- `@Environment(\.router)` without a host returned a real, unhosted router, so
  navigation silently did nothing.
- `awaitSheetDismissal` leaked its continuation if the router deallocated first.
- An uncancelled 1.25s task was left behind by every system-backed push or pop.

### Performance

- Destination, sheet and cover content views observed the router with
  `@ObservedObject`, so any router change — presenting a sheet included —
  invalidated every live destination and re-ran its `AnyView` builder. They take
  a plain reference now.
- The observation backend is resolved once at init behind a strategy, instead of
  an `if #available` plus an `as? ObservationRegistrar` unbox on every property
  read.
- Internal reads use the stored entries rather than the `path` getter, which
  mapped a fresh array per access.

### Known Gaps

- The reveal transition masks a `UIHostingController` view with a `UIView`, which
  UIKit logs as unsupported. Switching to a `CALayer` mask silences it but breaks
  the animation: `UIViewPropertyAnimator` animates view properties, so a layer
  transform snaps to its final value and the wipe disappears. Fixing both means
  masking a wrapper view this package owns rather than the hosting view.
- The animated `replaceTop` drops the entry below the new top, which SwiftUI sees
  as the element at that index changing. Whether it reuses the pushed screen's
  hosting controller or rebuilds it is unverified; a rebuild would flash and reset
  that screen's local state.

### Compatibility

- Minimum deployment target remains iOS 16.0. The dual-observation layer stays:
  `@Observable` semantics on iOS 17+, `ObservableObject` on iOS 16.
- The fallback is asymmetric — `@Environment` does not observe an
  `ObservableObject` — so send commands rather than rendering from stack state.

## 2.0.0 - 2026-08-12

### Breaking Changes

- Renamed the package, library product, source target, test target and import
  module from `KVRouter` to `KVRouterKit`.
- Consumers must replace `import KVRouter` with `import KVRouterKit` and select
  the `KVRouterKit` product in their app target.

### Added

- Selectable push/pop transitions with automatic reverse motion: Slide, Fade,
  Scale, Scale and Fade, Shared Axis, Depth, Reveal and 3D Flip.
- A value-based custom transition DSL backed by live UIKit navigation views.
- Native SwiftUI hero zoom on iOS 18+ with a compatible live-view fallback on
  iOS 16 and 17.
- Interactive leading-edge pop for custom transitions, including reversible
  percent-driven animation.
- Per-route transition overrides, transition source registration and graceful
  `.scaleAndFade` fallback when a hero source is unavailable.

### Changed

- Rebuilt custom transitions on `UIViewControllerAnimatedTransitioning` and
  `UIViewPropertyAnimator` to preserve controller identity and local SwiftUI
  state across push/pop operations.
- Scoped UIKit navigation-animation forcing to KVRouterKit-managed single push
  and pop mutations. This restores animation when SwiftUI passes
  `animated: false` on newer runtimes without affecting unrelated navigation
  controllers or bulk path changes.
- `.system` and iOS 18+ `.zoom` remain system-owned; KVRouterKit only restores
  their animated transaction and does not replace Apple's animator.
- Improved transition hierarchy, cleanup, interruption handling, Reduce Motion
  behavior and system-dismiss reverse animations.

### Fixed

- Restored `.system` push/pop animation on iOS 18.4 and iOS 26 runtimes.
- Restored native zoom push and reverse pop animation on iOS 18+.
- Removed black disappearing frames, stale overlay ordering and destination
  state resets caused by the previous snapshot/overlay approach.
- Prevented stale animation intent from leaking after bridge detachment or an
  unmatched navigation mutation.

### Compatibility

- Minimum deployment target remains iOS 16.0.
- The package builds in Swift 6 language mode with Swift tools 6.2.
- Public router types such as `KVAppRouter`, `KVRouterHost`, `KVAppRoute` and
  middleware protocols retain their existing names.

[Full release notes](docs/releases/2.0.0.md)

## 1.0.0

- Initial KVRouter release with type-safe SwiftUI routing, dynamic destinations,
  middleware, deep links, state restoration and targeted pop APIs.
