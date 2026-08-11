# KVRouterKit Scoped Navigation Animation Forcing Design

**Date:** 2026-08-12

## Goal

Restore push and pop animation on iOS 18 and later for custom transitions,
Apple's `.system` transition, and native hero zoom without changing the public
API or replacing `NavigationStack`.

The compatibility layer must:

- keep `NavigationStack` as the source of navigation state;
- make UIKit request `KVViewControllerTransitionAnimator` for custom operations;
- remain inactive for navigation controllers not managed by KVRouterKit;
- keep `.system` and native `.zoom` system-owned while ensuring their
  router-driven mutations remain animated;
- continue supporting the custom UIKit hero fallback on iOS 16 and 17;
- support router-driven and system-initiated single push and pop operations;
- avoid snapshots, duplicate navigation mutations, and per-frame SwiftUI work.

## Confirmed Runtime Behavior

The Example app was instrumented at the SwiftUI environment, transition
coordinator, navigation-controller delegate, and custom animator boundaries.

The same Shared Axis push produced these results:

| Runtime | Reduce Motion | Resolved backend | UIKit `animated` | Custom animator |
|---|---:|---|---:|---:|
| iOS 16.0 | `false` | `.custom` | `true` | Requested |
| iOS 18.4 | `false` | `.custom` | `false` | Not requested |
| iOS 26.2 | `false` | `.custom` | `false` | Not requested |

On iOS 18 and later, the router correctly creates a pending custom transition,
but SwiftUI reconciles the programmatic `NavigationStack` path through a UIKit
navigation mutation with `animated: false`. UIKit therefore skips
`navigationController(_:animationControllerFor:from:to:)` completely.

`withAnimation` creates a SwiftUI transaction; it does not guarantee that
SwiftUI's private navigation-stack coordinator will pass `animated: true` to
the underlying `UINavigationController`.

## Chosen Approach

Install a one-time Objective-C method-exchange compatibility shim for the UIKit
navigation mutation APIs. The method exchange is process-wide, but its behavior
is scoped by an associated policy object that exists only on a navigation
controller currently attached to KVRouterKit.

This follows the proven compatibility boundary used by
`davdroman/swiftui-navigation-transitions`, while adding stricter per-controller
and per-controller intent tracking so KVRouterKit does not force unrelated
navigation operations to animate.

## Alternatives Rejected

### Replace `NavigationStack`

A custom `UIViewControllerRepresentable` navigation container could directly
own every animated flag, but would replace SwiftUI's destination resolution,
path synchronization, state restoration, and native iOS 18 zoom integration.
The migration cost and behavioral risk are much larger than the compatibility
problem being fixed.

### Return to an overlay or snapshot renderer

Animating snapshots or a SwiftUI overlay avoids the UIKit animated flag, but it
reintroduces the black frames, hierarchy ordering errors, state resets, and
performance problems that the live-view UIKit transition engine replaced.

## Architecture

### One-time runtime installer

Add an internal runtime component that imports the Objective-C runtime and
exchanges these `UINavigationController` methods once per process:

- `setViewControllers(_:animated:)`;
- `pushViewController(_:animated:)`;
- `popViewController(animated:)`;
- `popToViewController(_:animated:)`;
- `popToRootViewController(animated:)`.

The exchanged implementation computes:

```text
effectiveAnimated = requestedAnimated || policy.shouldForceAnimation(mutation)
```

If no KVRouterKit policy is associated with that navigation controller, the
original `animated` value is forwarded unchanged.

The runtime installer is idempotent and thread-safe. It performs no transition
resolution and owns no router state.

### Scoped policy association

`KVNavigationControllerBridge.attach` installs a retained associated policy box
on the introspected navigation controller. The box holds a weak reference to the
bridge or coordinator so it cannot extend the router or host lifetime.

`detach` clears the association before releasing the delegate proxy. After
detachment, the exchanged UIKit methods immediately become pass-through for
that navigation controller.

The association is also replaced when the host moves to a different navigation
controller. Other navigation controllers in the app are never marked and keep
their original behavior.

### Operation classification

The policy classifies the UIKit mutation before deciding whether to force it.

Direct push and pop APIs provide the operation explicitly. For
`setViewControllers`, the policy compares controller identity and stack count:

- one appended controller with an unchanged prefix is a single push;
- one removed top controller with an unchanged prefix is a single pop;
- replacement, restoration, reordering, and multi-controller changes are not
  forced by this compatibility layer.

This keeps the fix aligned with the package's guaranteed single push and pop
scope. Existing restoration and bulk path behavior remains system-owned.

### Force-animation decision

The coordinator returns `true` for one of these scoped cases:

1. a router-driven `.system` or native `.zoom` request installed a matching,
   one-shot navigation animation intent before mutating the path;
2. a matching `.custom` transition transaction is pending; or
3. a recognized single pop originates from a controller with KVRouterKit
   transition metadata.

For `.custom`, UIKit also receives `KVViewControllerTransitionAnimator`. For
`.system` and native `.zoom`, the delegate returns no custom animator, leaving
the animation implementation entirely owned by UIKit and SwiftUI.

The following always return `false`:

- initial root installation;
- direct pushes performed outside a router request;
- replacement, restoration, and bulk stack mutations;
- mismatched or stale pending transactions and intents;
- any navigation controller not currently attached to KVRouterKit.

Reduce Motion still resolves custom motion to the existing short fade
descriptor. That fade requires an animated UIKit transaction, so the policy may
still force `animated: true` while the descriptor removes scale, rotation, mask,
and directional movement.

## Navigation Flows

### Router-driven custom push

1. The coordinator resolves `.custom` and installs the pending transaction.
2. The router appends one entry to the path.
3. SwiftUI calls a UIKit navigation mutation, possibly with `animated: false`.
4. The scoped policy recognizes the matching custom push and forwards
   `animated: true`.
5. UIKit asks the delegate proxy for an animation controller.
6. The coordinator returns the existing custom animator.
7. `didShow` completes the pending continuation and synchronizes metadata.

### Router-driven custom pop

The flow mirrors push. The pending transaction is installed before the path is
shortened, so the policy can force the matching single pop before UIKit asks for
the reverse animator.

### Router-driven system and native-zoom navigation

Before changing the path, the coordinator records a one-shot animation intent
for the requested push or pop. If SwiftUI later calls UIKit with
`animated: false`, the scoped policy consumes the matching intent and forwards
`animated: true`. No custom animator is returned, so `.system` keeps Apple's
standard transition and iOS 18+ `.zoom` keeps the native hero implementation.

The intent is cleared when UIKit consumes it, when `didShow` arrives, on bridge
detachment, or by a short watchdog if SwiftUI emits no matching mutation.

### System-initiated custom pop

When SwiftUI's environment dismiss or navigation back action shortens the path
without a router pending transaction, the policy inspects metadata for the
current top controller. A managed pop is forced to animate for every backend.
The delegate proxy constructs a metadata fallback animator only for `.custom`;
system and native-zoom pops remain system-owned.

### Interactive pop

KVRouterKit already begins its custom interactive pop through
`popViewController(animated: true)`. The compatibility layer observes that the
requested value is already true and leaves it true. It must not create a second
transaction, gesture, or interaction controller.

## Failure Handling

- Runtime installation failure leaves navigation behavior unchanged and allows
  operations to fail open to their current system behavior.
- A missing or released policy box forwards the original animated flag.
- An unrecognized stack mutation forwards the original animated flag.
- A stale or mismatched custom transaction or system/native intent is not
  forced and is later cleared by its watchdog.
- Detachment during an active operation clears the association only after the
  coordinator performs its existing cancellation cleanup.

No runtime failure may block the path mutation or leave the navigation stack in
an intermediate state.

## Testing

Add regression tests that fail with the current implementation:

1. An attached coordinator with a pending custom push receives a UIKit mutation
   requested with `animated: false`; UIKit must request a
   `KVViewControllerTransitionAnimator` and report `willShow(animated: true)`.
2. The equivalent custom pop must request the reverse animator.
3. A system-initiated pop for a controller with custom metadata is forced and
   receives a custom animator.
4. Router-driven `.system` and native `.zoom` operations report
   `willShow(animated: true)` without receiving a custom animator.
5. Managed system-initiated `.system` pops are also animated.
6. An unattached navigation controller and a direct external push preserve
   `animated: false`.
7. Initial root installation, replacement, and bulk mutations are not forced.
8. Repeated bridge attachment does not reinstall or recursively invoke the
   exchanged methods.
9. Interactive pop continues to use one percent-driven transition.

Run the full package suite and Example builds, followed by live Simulator checks
on iOS 16.0, iOS 18.4, and iOS 26.2. Runtime diagnostics must confirm that the
custom animator is requested on all three versions while system and native zoom
remain system-owned and still receive an animated UIKit transaction.

## Performance and Safety Boundaries

- One associated-object lookup and one small policy decision occur per UIKit
  navigation mutation; there is no per-frame compatibility work.
- The shim never captures views or allocates transition images.
- Animation timing, transforms, hierarchy, and cleanup remain owned by the
  existing `KVViewControllerTransitionAnimator`.
- The exchanged implementation calls the original UIKit implementation exactly
  once.
- Public KVRouterKit APIs remain source-compatible.
- Minimum deployment remains iOS 16.

## Success Criteria

- Scale, Shared Axis, Depth, Reveal, 3D Flip, custom DSL, and fallback hero
  transitions animate on iOS 16 and iOS 18 or later.
- Native hero zoom remains system-provided on iOS 18 or later.
- `.system` retains Apple's original animation and gesture behavior.
- System dismiss and router pop both receive the matching reverse custom
  transition.
- Previous SwiftUI screens preserve identity and local state.
- No black frame, duplicate animation, recursive navigation call, or interaction
  regression is introduced.
