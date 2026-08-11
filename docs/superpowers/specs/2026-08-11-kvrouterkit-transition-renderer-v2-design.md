# KVRouterKit Transition Renderer V2 Design

**Date:** 2026-08-11

## Goal

Replace the first custom transition renderer with a state-preserving, operation-aware pipeline that fixes four observed problems:

- the disappearing screen renders above the pushed destination;
- custom transitions can show a black snapshot;
- returning from a custom transition rebuilds the previous SwiftUI screen and resets local state;
- custom transitions are visibly less smooth than system navigation in a Debug Simulator build.

The public `KVNavigationTransition`, `KVAppRouter`, and `KVRouterHost` APIs remain source-compatible. Native system navigation and native iOS 18 zoom remain unchanged.

## Root Causes

### Navigation identity changes

The current host alternates between a raw `NavigationStack` and a stack wrapped in `KVTransitionLayer(AnyView(...))`. That changes the structural identity of the navigation subtree when a custom transition starts and ends. SwiftUI can recycle the subtree and rebuild destination-local state.

### Push uses pop-style z-order

The current renderer chooses layer order from `isInteractive` rather than the navigation operation. A non-interactive push places the outgoing full-screen snapshot above the incoming destination. This makes the old screen appear to remain on top while it disappears.

### Snapshot source is unreliable

The current probe stores an arbitrary UIKit superview from a SwiftUI background representable. Capturing that superview with `drawHierarchy(afterScreenUpdates: true)` does not guarantee that the captured object owns the visible screen hierarchy. Transparent or incomplete captures are later rendered as a black full-screen image.

### Main-thread and render cost is too high

The first renderer captures full-resolution screens at both ends of transitions, performs synchronous hierarchy drawing on the main actor, and applies blur, masks, large scales, and 3D rotation to full-screen layers. Destination views also observe coordinator changes they do not need, broadening invalidation during interactive progress updates.

## Architecture

### Stable navigation surface

`KVRouterHost` will always render the same navigation-surface structure:

1. a stable `NavigationStack` child;
2. an optional cached background snapshot;
3. an optional lightweight transition overlay.

The stack will not move between conditional branches and will not be conditionally erased to `AnyView`. A stable modifier/container will resolve to identity transforms while idle and transition transforms while active.

Destination content will observe the router only. It will receive the coordinator as a non-observed reference only where a one-time native-zoom lookup is required. Coordinator progress changes must not invalidate every destination body.

### Render plan

The coordinator will expose an internal render plan derived from operation and phase. The plan explicitly describes:

- whether path mutation happens before or after animation;
- whether the cached previous screen is below or above the live stack;
- which live layer role is incoming or outgoing;
- whether a transition requires a snapshot.

The required plans are:

| Flow | Background | Foreground | Path mutation |
|---|---|---|---|
| Custom push | Previous-screen snapshot | Incoming live stack | Before animation |
| Programmatic custom pop | Previous-screen snapshot | Outgoing live stack | After animation |
| Interactive custom pop | Previous-screen snapshot | Outgoing live stack | On successful completion |
| Cancelled interactive pop | Previous-screen snapshot | Outgoing live stack | Never |

This ordering matches normal iOS navigation: a new destination covers the previous screen on push, and the current screen leaves above the previous screen on pop.

### Push sequence

1. Resolve the transition and verify required hero metadata.
2. Capture the currently visible host region once and cache it for the current entry or root.
3. Install the render plan with progress `0`.
4. Mutate the path without a system animation so the destination becomes the live stack.
5. Animate the incoming live stack to identity over the cached previous screen.
6. Remove transient render state without changing the navigation-surface identity.

No second full-screen capture runs after the push.

### Pop sequence

1. Resolve the transition and load the cached snapshot for the destination below the current entry.
2. Install the render plan while leaving the path unchanged.
3. Animate the current live stack out over the cached previous screen.
4. Mutate the path without animation only after progress reaches `1`.
5. Clear the removed entry's transition and snapshot metadata.
6. Remove transient render state without replacing the navigation subtree.

Interactive pop uses the same structure. Cancelling animates progress back to `0` and leaves the path untouched.

## Snapshot Pipeline

The host probe will record both the containing `UIWindow` and the host frame in window coordinates. It will not expose an arbitrary SwiftUI wrapper as the capture root.

Snapshot capture will:

1. render the visible window region with `afterScreenUpdates: false`;
2. fill the renderer with `systemBackground` before drawing so transparent regions cannot display as black;
3. check the Boolean result from `drawHierarchy`;
4. fall back to `window.layer.render(in:)` when hierarchy drawing fails;
5. crop to the host frame and store an image with the correct screen scale;
6. reject empty, non-finite, or zero-area capture regions.

Only custom transitions that need a previous-screen background will capture. Programmatic and interactive pop reuse the snapshot captured before the corresponding push. Native system and native zoom transitions do not capture full-screen images.

If a required cached snapshot is unavailable, the operation falls back to `.system` before mutating the path. It must not animate over a black placeholder.

## Motion Language

The renderer will favor transform-only motion and small amplitudes:

| Style | Incoming motion | Outgoing/background motion |
|---|---|---|
| Fade | Opacity `0 -> 1` | Static or subtle dim |
| Slide | Full directional entrance | `4-6%` parallax |
| Scale | Scale about `0.96 -> 1`, light fade | Static or scale to about `0.985` |
| Scale + fade | Scale about `0.94 -> 1`, opacity `0 -> 1` | Very light scale/dim |
| Shared axis | `10-12%` directional offset, light fade | `4-6%` reverse offset |
| Depth | Scale about `0.97 -> 1`, light fade | Small scale/dim, no full-screen blur |
| Reveal | Lightweight rectangular reveal mask | Static background |
| 3D flip | About `20-24` degrees, light fade | Small counter-rotation only when visually necessary |

Most styles will complete in `0.28-0.38` seconds. Springs use high damping to avoid bounce during navigation. Pop motion has explicit role-specific endpoints instead of blindly reversing every push transform.

Reduce Motion uses a short crossfade and skips scale, blur, masks, and rotation.

## Hero Zoom

iOS 18 and later continue to use SwiftUI's native `matchedTransitionSource` and `.navigationTransition(.zoom)` implementation.

On iOS 16 and 17, the custom hero transition keeps a source snapshot but avoids transforming two full-screen layers simultaneously. The source snapshot expands toward the destination while the live destination uses a restrained opacity/scale entrance. Pop reverses toward the stored source geometry. Missing source or snapshot data falls back before mutation rather than rendering a blank layer.

## Performance Boundaries

- No full-screen blur during navigation.
- No destination-level observation of interactive progress.
- No full-screen capture after a completed push.
- No new capture at the beginning of pop.
- No conditional type changes around the live `NavigationStack`.
- Interactive updates are scoped to the transition surface and do not rebuild destination content.
- Snapshot memory remains bounded and removed with dead navigation entries or memory warnings.

Debug Simulator performance may remain below a Release build on device, but the renderer must avoid visible black frames, hierarchy swaps, and broad invalidation in both configurations.

## Failure Handling

- Capture failure before custom push: use `.system` and proceed normally.
- Missing cached destination snapshot before pop: use `.system` and proceed normally.
- Missing hero source: use `.scaleAndFade` only when a valid previous-screen snapshot exists; otherwise use `.system`.
- Scene interruption: settle to the operation's safe endpoint, perform any required deferred mutation exactly once, and clear transient layers.
- Interactive cancellation: return to progress `0`, leave the path unchanged, and preserve cached snapshots.

## Testing

Add pure regression coverage for:

- push render plans placing the previous snapshot below incoming live content;
- pop and interactive-pop plans placing outgoing live content above the previous snapshot;
- push mutation occurring before animation;
- programmatic and interactive pop mutation occurring only after completion;
- cancelled interactive pop never mutating the path;
- snapshot failure resolving to `.system` rather than a custom black layer;
- the revised motion endpoints and Reduce Motion behavior;
- removed entries releasing cached snapshots and hero metadata.

Run the full package test suite and generic package/example builds. Manual Simulator validation must confirm:

1. local `@State` on a previous screen survives push and pop;
2. no outgoing screen covers a pushed destination incorrectly;
3. no black frames appear during push, pop, or cancellation;
4. all styles feel smooth in Debug Simulator and are checked again in Release when practical;
5. native iOS 18 hero zoom remains unchanged;
6. iOS 16-17 hero fallback remains functional when a runtime is available.

## Compatibility

- Minimum deployment target remains iOS 16.
- Public API names and call sites remain unchanged.
- Modal presentation behavior remains unchanged.
- `.system` remains the default transition.
- Native iOS 18 zoom remains system-owned.
