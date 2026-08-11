# KVRouterKit UIKit Transition Engine V3 Design

**Date:** 2026-08-11

## Goal

Replace the snapshot-driven SwiftUI renderer with a UIKit-backed navigation
transition engine that is as close as practical to system navigation performance
while preserving `NavigationStack` ownership of navigation state.

The redesign must:

- animate the real navigation-controller views instead of full-screen images;
- preserve destination identity, local SwiftUI state, scroll position, and input state;
- support route-specific push and pop transitions;
- provide smooth interactive pop driven by UIKit;
- use native SwiftUI hero zoom on iOS 18 and later;
- provide a live-view hero zoom fallback on iOS 16 and 17;
- replace the arbitrary SwiftUI custom-transition closure with a constrained,
  compositor-friendly transition DSL;
- remove black frames, incorrect layer ordering, and per-frame SwiftUI invalidation.

Custom transitions are guaranteed for navigation mutations performed through
`KVAppRouter`. Direct `NavigationLink` pushes or external path mutations keep
system navigation behavior.

## Reference Architecture

The design was informed by `davdroman/swiftui-navigation-transitions`, inspected
at commit `0b7bd5ff23b36882354bd53ef8c09c275c1d696a` from the local SwiftPM cache.

The relevant architectural lessons are:

- introspect SwiftUI's underlying `UINavigationController` rather than replacing
  the first-party navigation stack;
- provide transitions through `UINavigationControllerDelegate`;
- animate real `fromView` and `toView` instances with `UIViewPropertyAnimator`;
- use `UIPercentDrivenInteractiveTransition` for scrubbed pop gestures;
- compose transition primitives into a single transient property state before
  submitting animation blocks;
- reset all mutated view properties after completion or cancellation.

KVRouterKit will not depend on the complete reference package. It will add only
`SwiftUIIntrospect` and will own its route-resolution, transition DSL, hero zoom,
middleware, and lifecycle behavior.

## Current Renderer Problems

### Synchronous full-screen capture

Every custom push calls `UIWindow.drawHierarchy` on the main actor at screen
scale. This introduces a large one-time stall immediately before animation and
allocates a full-resolution image. A modern three-times-scale phone can require
tens of megabytes of transient pixel memory across the active snapshot and
rendering copies.

### Per-frame SwiftUI invalidation

`KVTransitionCoordinator.progress` is published. `KVRouterHost` observes it and
rebuilds the full-screen transition composition during animation and interactive
dragging. The live `NavigationStack` is erased to `AnyView` and transformed as a
single large SwiftUI surface.

### Permanently expensive modifier chain

Built-in transitions always pass through opacity, scale, offset, blur,
`rotation3DEffect`, and mask modifiers even when most values are identity. Large
masked or 3D-transformed SwiftUI trees can trigger additional offscreen passes.

### Snapshot-based state restoration

Programmatic and interactive pop render an image of the previous screen instead
of its real view. The router defers the path mutation until after animation,
which creates a separate navigation lifecycle from UIKit and makes cancellation,
hierarchy ordering, and state preservation more fragile.

## Scope

The custom engine applies to:

- `push` and `pushView`;
- `pop`;
- `popTo`, `popToRoot`, and `pop(count:)`, represented as one top-to-target pop;
- interactive edge pop for custom transitions.

The following remain system-owned:

- `replaceTop` and `replaceTopWithView`;
- `setPath` and restoration mutations;
- sheets and full-screen covers;
- direct `NavigationLink` navigation;
- external path binding mutations.

The minimum deployment target remains iOS 16.

## Core Architecture

### Stable SwiftUI host

`KVRouterHost` always renders a normal `NavigationStack`. The following renderer
v2 structures are removed from the host:

- full-screen transition `ZStack`;
- background snapshots;
- `GeometryReader`-driven transition layers;
- progress completion observer;
- custom edge gesture overlay;
- full-screen hero layer.

The host adds one introspection modifier that reports the underlying
`UINavigationController` to the coordinator. Native iOS 18 zoom modifiers remain
on source and destination SwiftUI content.

### Navigation controller bridge

`KVNavigationControllerBridge` attaches a delegate proxy to the introspected
navigation controller.

The bridge must:

- attach idempotently;
- retain the original SwiftUI delegate for the lifetime of the attachment;
- forward every optional delegate callback it does not explicitly intercept;
- restore the original delegate when detached, but only if the installed
  delegate is still KVRouterKit's proxy;
- detach from an old navigation controller before attaching to a new one;
- avoid replacing another library's delegate while a transition is active;
- fail open to system navigation if attachment is unavailable.

The proxy intercepts:

- animation-controller resolution;
- interaction-controller resolution;
- `willShow` and `didShow` completion signals;
- transition completion and cancellation cleanup.

No method swizzling is part of the primary design. KVRouterKit owns router path
mutations and wraps custom operations in an animated transaction so UIKit asks
the delegate for an animator. A narrowly scoped animation-forcing shim may only
be reconsidered if integration tests prove that a supported iOS version ignores
the animated transaction.

### Transition transaction

Before mutating the path, the coordinator creates one
`KVTransitionTransaction` containing:

- a unique transaction identifier;
- push or pop operation;
- source and destination entry identifiers;
- resolved backend;
- compiled transition descriptor;
- animation timing;
- interactive state, when applicable;
- middleware decision task, when applicable;
- completion continuation;
- cleanup state preventing duplicate completion.

The transaction is installed before the router mutation. The router then mutates
the path inside an animated SwiftUI transaction. When UIKit requests an animation
controller, the delegate proxy validates that the UIKit operation matches the
pending transaction and returns a custom animator.

The router's FIFO queue resumes only when UIKit reports the transaction complete,
cancelled, safely skipped, or timed out.

### Backend resolution

Backend resolution remains per navigation entry:

| Requested transition | iOS 16-17 | iOS 18+ |
|---|---|---|
| `.system` | System | System |
| `.zoom` with valid source | UIKit live hero | Native SwiftUI zoom |
| `.zoom` without source | UIKit scale-and-fade | UIKit scale-and-fade |
| Other built-in style | UIKit animator | UIKit animator |
| DSL custom style | UIKit animator | UIKit animator |

Returning `nil` from the delegate for `.system` and native zoom leaves animation
and interaction completely system-owned.

## UIKit Animator

### Transition context setup

`KVViewControllerTransitionAnimator` obtains the transition container, `fromView`,
and `toView` from `UIViewControllerContextTransitioning`.

It must:

1. force destination layout before measuring final geometry;
2. set both views to the context-provided initial and final frames;
3. insert `toView` above `fromView` for push;
4. insert `toView` below `fromView` for pop;
5. capture every mutable property before applying a transition;
6. apply compiled initial states synchronously;
7. animate to compiled final states with one `UIViewPropertyAnimator`;
8. restore all transient properties after completion or cancellation;
9. call `completeTransition(!transitionWasCancelled)` exactly once.

The animator is interruptible and caches one `UIViewPropertyAnimator` per UIKit
transition context, matching UIKit's `interruptibleAnimator(using:)` contract.

### Mutable properties

The engine may animate only compositor-friendly state:

- `UIView.alpha`;
- `UIView.center`;
- `UIView.transform` or `CALayer.transform`;
- `CALayer.cornerRadius`;
- `CALayer.zPosition`;
- a lightweight mask view's transform for reveal.

The engine does not animate full-screen blur, call `drawHierarchy`, create
full-screen `UIImage` instances, or enable `shouldRasterize`.

### Property restoration

The animator stores original values for:

- frame and center;
- alpha;
- affine and 3D transforms;
- anchor point if changed;
- corner radius and clipping flags;
- z-position;
- mask;
- double-sided layer behavior;
- user-interaction state.

Completion and cancellation restore the appropriate hierarchy and every saved
property. No transformed view may escape the transition lifecycle.

## Interactive Pop

### Gesture ownership

Custom transitions use a `UIScreenEdgePanGestureRecognizer` attached directly to
the navigation controller. The edge follows the interface layout direction.

System transitions and native iOS 18 zoom retain the system interactive pop
gesture. Only the recognizer appropriate to the current top entry is enabled.

### Interaction lifecycle

On gesture begin:

1. validate that the navigation controller is not at root and no transition is active;
2. resolve the top entry's pop transition;
3. create a `UIPercentDrivenInteractiveTransition`;
4. mark the operation as router-controlled to avoid duplicate middleware work;
5. start the asynchronous pop-middleware decision immediately;
6. call `popViewController(animated: true)` so UIKit creates the real pop context.

On change, normalized leading translation updates the percent-driven controller.
No SwiftUI observable state changes per frame.

On end, progress and leading velocity determine the user's intent. The
interaction finishes only when both the gesture decision and middleware allow
the pop. Otherwise it cancels. Starting middleware at gesture begin minimizes
the time spent waiting after release.

On failure or cancellation, the interaction controller cancels, the original
entry remains live, and all temporary state is discarded.

Integration tests must verify exactly when SwiftUI updates the bound path during
an interactive navigation-controller pop on iOS 16, 17, and 18. If a supported
version proposes the shorter path before UIKit resolves cancellation, the path
binding will gate that proposal until the transition outcome is known.

## Hero Zoom

### iOS 18 and later

Native hero zoom remains implemented with:

- `matchedTransitionSource(id:in:)` on the registered source;
- `.navigationTransition(.zoom(sourceID:in:))` on the destination;
- the host namespace shared through the environment.

The delegate supplies no custom animator for this transaction. UIKit and SwiftUI
own the push, pop, cancellation, and Reduce Motion behavior.

### iOS 16 and 17

The fallback uses live navigation views rather than full-screen snapshots.

The source registry records weak source-view references, current window-space
frames, and corner radii through a lightweight UIKit probe.

For push:

1. resolve the source frame into transition-container coordinates;
2. layout the live destination at its final full-screen frame;
3. derive X and Y scale factors from source and destination geometry;
4. initialize the destination's center, transform, clipping, and corner radius
   so it occupies the source frame;
5. animate destination center and transform to full-screen identity;
6. apply only a subtle depth treatment to the outgoing screen.

For pop:

1. place the real previous screen below the outgoing screen;
2. layout it and resolve the current source frame from its live hierarchy;
3. animate the outgoing live screen from full-screen identity into that frame;
4. reveal the unchanged previous screen underneath;
5. restore source and destination properties after completion or cancellation.

If the source is missing, outside the active hierarchy, non-finite, or empty,
the transaction resolves to scale-and-fade before animation begins. No stale
geometry or image fallback is used.

## Transition DSL

### Animation type

`SwiftUI.Animation` is opaque and cannot reliably provide duration or timing
parameters to UIKit. It is replaced with `KVTransitionAnimation`, a value type
that resolves to `UITimingCurveProvider`.

Supported factories include:

```swift
.easeInOut(duration: 0.35)
.easeOut(duration: 0.3)
.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)
.spring(response: 0.4, dampingFraction: 0.9)
```

Names remain close to SwiftUI animation syntax to minimize migration cost.

### Custom transition definition

The arbitrary custom SwiftUI transform closure is removed and replaced with a
value-based API:

```swift
let cardTransition = KVNavigationTransition.custom(
    push: .init(
        incoming: .identity
            .relativeOffset(x: 1)
            .scale(0.98)
            .opacity(0),
        outgoing: .identity
            .relativeOffset(x: -0.08)
            .scale(0.97)
    ),
    pop: .mirrored,
    animation: .spring(response: 0.38, dampingFraction: 0.9),
    interactiveBack: true
)
```

`KVTransitionViewState` supports ordered composition of:

- opacity;
- point offset;
- container-relative offset;
- uniform or independent X/Y scale;
- 2D rotation;
- 3D rotation and perspective;
- corner radius;
- z-position;
- reveal mask origin.

The compiler folds the ordered primitive list into one property state before the
animation starts. `.mirrored` swaps the push incoming and outgoing endpoint
states for pop. This naturally returns the outgoing screen toward the push
source while restoring the previous screen from its push background state. An
explicit pop definition remains available for geometric sign changes or other
asymmetric motion.

Unsupported arbitrary view modifiers, filters, layout mutations, and per-frame
closures are intentionally excluded.

## Built-In Motion Language

All built-in styles compile through the same DSL and animator path.

| Style | Incoming view | Outgoing or background view |
|---|---|---|
| Fade | Fade in over the previous screen | Remain opaque |
| Slide | Enter from the requested edge | Move 4-6% in the opposite direction |
| Scale | Scale from about `0.96` | Scale subtly toward `0.985` |
| Scale and fade | Scale from about `0.94` and fade in | Dim or scale only slightly |
| Shared axis | Move 10-14% and fade in | Move 4-6% in the opposite direction |
| Depth | Scale from about `1.04` | Scale toward about `0.96` |
| Reveal | Expand a mask over the previous screen | Remain visible underneath |
| 3D flip | Rotate about 65-75 degrees to identity | Apply a small counter-rotation |
| Zoom | Source frame to full screen | Apply a subtle depth treatment |

No built-in transition makes both full-screen views transparent simultaneously.
The container background is set from the destination or system background so a
temporary empty composition cannot appear black.

The 3D flip deliberately avoids 90-180 degree endpoints. This prevents a moment
where both views are edge-on or their hidden back faces expose the container.

Reduce Motion compiles every custom style to a short fade and removes scale,
rotation, reveal, and hero geometry transforms.

## Lifecycle and Failure Handling

### Attachment lifecycle

- Attach when introspection reports a navigation controller.
- Reattach safely if SwiftUI replaces the controller.
- Restore the previous delegate on host disappearance.
- Cancel or settle active work before detaching.
- Clear weak source metadata for removed navigation entries.

### Failure behavior

- Introspection unavailable: use system navigation immediately.
- Delegate conflict: emit a DEBUG warning and use system behavior rather than
  fighting another delegate during an active transition.
- Missing transition-context views: restore any changed state and complete safely.
- Missing hero source: resolve to scale-and-fade before mutation.
- Scene interruption: finish programmatic navigation at its safe endpoint and
  cancel interactive navigation back to its start.
- Reduce Motion changes mid-transition: settle the active transition and use the
  reduced style on the next operation.
- Completion callback missing: a watchdog clears the transaction and resumes the
  router queue without performing duplicate mutations.

All completion paths are idempotent.

## Implementation Risk Checkpoints

Implementation begins with three narrow integration spikes before the built-in
styles are migrated:

1. Verify on iOS 16, 17, and 18 that a router-owned animated path mutation asks
   the introspected navigation controller delegate for a custom animator. If a
   supported version does not, add the smallest possible animation-forcing shim
   and cover it with an OS-specific integration test.
2. Verify when `NavigationStack` proposes its bound-path update during an
   interactive `popViewController` operation. If the proposal arrives before
   UIKit resolves finish or cancellation, introduce a coordinator-owned path
   gate that defers builder cleanup and commits or discards the proposal exactly
   once with the interaction outcome.
3. Verify live hero geometry across safe areas, navigation bars, rotation, and
   scroll containers. Geometry that cannot be converted into the transition
   container deterministically must resolve to scale-and-fade rather than add a
   snapshot-based exception.

These checkpoints are exit criteria for the engine foundation. Style migration
does not begin until programmatic push/pop, interactive cancellation, and live
hero fallback have each passed their checkpoint on the available runtimes.

## Dependency and Package Changes

`Package.swift` adds the `swiftui-introspect` package and the
`SwiftUIIntrospect` product to `KVRouterKit`.

The implementation removes the production need for:

- `KVSnapshotCapture` and `KVSnapshotCache`;
- `KVTransitionLayer`;
- `KVTransitionVisualState` as a SwiftUI render state;
- `KVTransitionRenderPlan`;
- `KVAnimationCompletionObserver`;
- published transition progress in `KVTransitionCoordinator`.

Equivalent pure descriptor logic may keep familiar names only where they remain
accurate for the UIKit engine.

## Testing Strategy

### Unit tests

Add deterministic tests for:

- backend resolution by OS capability and hero-source availability;
- primitive ordering and transform composition;
- mirrored push-to-pop conversion;
- built-in transition descriptors;
- animation timing resolution;
- Reduce Motion compilation;
- invalid hero geometry fallback;
- transaction completion idempotency and watchdog behavior.

### Animator tests

Use test view controllers and a controlled transition context to verify:

- push and pop hierarchy ordering;
- initial, animation, and completion properties;
- cancellation restoration;
- source-to-container coordinate conversion;
- interactive `fractionComplete` behavior;
- no simultaneous transparent full-screen views;
- no retained masks or 3D properties after completion.

### Router and integration tests

Verify:

- FIFO navigation remains ordered;
- programmatic push and pop resume only after UIKit completion;
- interactive finish mutates the path once;
- interactive cancel preserves the path and view builders;
- middleware allows or cancels interactive pop without duplicate callbacks;
- `popTo`, `popToRoot`, and `pop(count:)` animate top-to-target correctly;
- system and native zoom operations never receive a custom animator.

### UI and state-preservation tests

The example transition gallery must cover every built-in style and verify:

- scroll position remains unchanged after push and pop;
- text field contents and focus state are not rebuilt;
- toggles and local `@State` survive navigation;
- interactive finish and cancellation leave correct hierarchy;
- no black frame appears at progress `0`, `0.5`, or `1`;
- RTL edge behavior is correct;
- native iOS 18 zoom and iOS 16-17 fallback both work when runtimes are available.

## Performance Verification

Add internal signposts around:

- transaction preparation;
- delegate animator resolution;
- destination layout and animator setup;
- animation completion;
- interactive begin and settle.

Benchmark every built-in style for at least 20 push/pop cycles.

Acceptance gates:

- zero `drawHierarchy` calls during navigation;
- zero full-screen image allocations by the transition engine;
- zero SwiftUI observation updates driven by transition progress;
- animator setup after destination layout is approximately under 2 ms in the
  example gallery;
- no transition hitch over 100 ms in a Release benchmark run;
- custom frame pacing remains within approximately 20 percent of `.system` in
  the same gallery flow;
- repeated transitions show no accumulating memory growth;
- cancellation has no extra full-screen allocation or destination rebuild.

Performance is checked first in Release Simulator and then on a physical device.
Debug Simulator remains a correctness target, but destination construction cost
from the host application is distinguished from transition-engine overhead.

## System-Initiated Pop and Dismissal Amendment

Custom transitions must also apply when a single pop is initiated outside
`KVAppRouter.pop()`, including the navigation-bar back button and
`@Environment(\.dismiss)`. The package does not replace SwiftUI's `DismissAction`;
instead, the navigation-controller delegate resolves an external pop from the
outgoing view controller's retained transition metadata.

Each pushed view controller is associated with the resolved transition selected
for that entry. When `animationControllerFor:from:to:` receives `.pop` without a
router-owned pending transaction, the delegate asks the coordinator for an
external-pop animator using the metadata attached to `fromVC`. System transitions
and iOS 18+ native zoom return `nil`, preserving Apple's animator. Custom and
iOS 16-17 live-view zoom return the same interruptible animator used by
router-owned pops.

The custom edge gesture remains the authoritative interactive path. Its
`UIPercentDrivenInteractiveTransition` scrubs the mirrored pop descriptor and
calls `cancel()` to reverse from the current gesture progress back to the exact
pre-pop state. A custom transition may still provide an explicit pop stage or
disable interactive back.

System-initiated pops have an intentional middleware limitation: SwiftUI has
already requested the path mutation before asynchronous middleware can finish,
so middleware runs as a post-pop callback and cannot veto that operation. Apps
that need cancellable pre-pop middleware use `KVAppRouter.pop()` (or the package's
router-backed dismiss convenience). This avoids method swizzling and private API
while keeping system back, SwiftUI dismiss, router pop, and swipe pop visually
consistent.

Additional tests cover:

- external single-pop animator resolution from outgoing controller metadata;
- no interception for `.system` or native zoom;
- metadata cleanup after controllers leave the stack;
- interactive finish and cancellation using the same mirrored descriptor;
- system dismiss completion without duplicate path mutation or middleware calls.

## Migration

Built-in transition names and router push/pop call sites remain unchanged.

Breaking changes are limited to the transition customization surface:

- custom SwiftUI transform closures migrate to the value-based DSL;
- `SwiftUI.Animation` overrides migrate to `KVTransitionAnimation` factories.

README examples and the gallery will include side-by-side migration examples.

## Success Criteria

The redesign is complete when:

1. all custom push and pop styles animate real UIKit navigation views;
2. previous SwiftUI screens preserve local state and identity;
3. no full-screen snapshot renderer remains in the custom navigation path;
4. interactive pop is driven by UIKit without per-frame SwiftUI updates;
5. iOS 18 zoom is system-native and iOS 16-17 zoom uses live-view geometry;
6. every transition completes and cancels without stale transforms or masks;
7. the test, state-preservation, visual, and performance gates pass.
