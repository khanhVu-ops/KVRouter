# KVRouterKit Scale and Flip Motion Polish

**Date:** 2026-08-11

## Goal

Replace the current built-in `scale` and `flip3D` motion presets with transitions that are visually clear, reversible, and smooth during both normal and interactive push/pop navigation.

The public API remains unchanged:

```swift
.scale
.flip3D(axis:)
```

## Scope

This change only affects the motion definitions and internal animator behavior used by `.scale` and `.flip3D`. It does not change system transitions, hero zoom, other custom presets, route state handling, or the push/pop-only support boundary.

## Scale: Collapse and Reveal

The selected direction is option A from the visual study.

On push:

- The outgoing screen scales from `1.0` to `0.84` and fades from `1.0` to `0.0`.
- The incoming screen starts at scale `0.94` and opacity `0.0`, then resolves to identity and full opacity.
- The incoming animation begins slightly after the outgoing animation, creating a clear replacement instead of a muddy crossfade.
- The transition uses a fast ease-out cubic curve with a duration of `0.34` seconds.

On pop, the two endpoint roles are mirrored. This makes the outgoing destination collapse toward its original incoming state while the previous screen grows back from the state it reached during push.

`KVTransitionDescriptor` will carry internal per-endpoint delay factors. Scale uses an incoming delay factor of `0.08` and no outgoing delay. These values are not public API and remain compatible with `UIViewPropertyAnimator` fraction-driven interactive transitions.

## 3D Flip: True 180-Degree Card

The two live controller views behave as the front and back faces of one virtual card.

On push:

- The outgoing screen rotates from `0` to `-180` degrees.
- The incoming screen starts at `+180` degrees and rotates to `0`.
- Both faces use the same perspective magnitude and vanishing point.
- Both faces hide their back side so UIKit swaps visible content naturally around the 90-degree midpoint.
- `.vertical` rotates around the Y axis and `.horizontal` rotates around the X axis, preserving the existing API meaning.
- The transition uses a symmetric ease-in-out cubic curve with a duration of `0.50` seconds.

Pop mirrors the endpoint roles and therefore runs the card turn in the opposite direction. Interactive swipe pop drives the same interruptible animator, and cancellation reverses from the exact current angle.

## Rendering and Performance

- Continue animating live views; do not introduce snapshots.
- Do not add blur, Core Image filters, or forced rasterization.
- Keep all motion inside the existing interruptible `UIViewPropertyAnimator` path.
- Preserve controller view state and SwiftUI hosting hierarchy before, during, and after cancellation.
- Keep the transition container on a non-black system background so the edge-on flip midpoint cannot expose a black frame.
- Restore alpha, transform, layer perspective-related state, backface settings, and interaction state after completion or cancellation.

## Accessibility

When Reduce Motion is enabled, both presets continue to compile to the existing short fade-only descriptor. The 180-degree rotation and scale collapse are not used in that mode.

## Testing

Automated tests will verify:

- Scale push endpoints use outgoing scale `0.84` with zero opacity and incoming scale `0.94` with zero opacity.
- Scale pop mirrors the push endpoint roles.
- Scale timing includes the intended incoming delay without disabling interactive back.
- Flip push endpoints use `+180` and `-180` degrees with matching perspective.
- Flip pop reverses the endpoint angles.
- The built-in animation durations and timing curves match the new presets.
- Completion and cancellation restore all managed live-view state.

Simulator QA will cover normal push, system back, `dismiss`, completed swipe pop, cancelled swipe pop, and repeated transitions on both iOS 16 and the latest available runtime.

## Success Criteria

- Scale reads as screen 1 collapsing away and screen 2 appearing, without a prolonged overlap or black frame.
- Flip visibly turns the full navigation surface by 180 degrees and reveals the destination as its back face.
- Push, pop, interactive completion, and interactive cancellation remain visually continuous.
- The transition engine adds no snapshot allocation or new offscreen-rendering effect.
