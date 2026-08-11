# Changelog

All notable changes to KVRouterKit are documented in this file.

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
