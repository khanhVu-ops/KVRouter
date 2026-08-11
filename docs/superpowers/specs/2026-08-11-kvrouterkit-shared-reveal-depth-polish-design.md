# KVRouterKit Shared Axis, Reveal, and Depth Motion Polish

**Date:** 2026-08-11

## Goal

Replace the current built-in Shared Axis, Reveal, and Depth motion definitions with the approved Visual Companion directions while preserving the existing live-view, interruptible push/pop engine.

The public API remains unchanged:

```swift
.sharedAxis(axis:)
.reveal(origin:)
.depth
```

## Scope

This change updates only the three built-in presets, their default timing curves, and the internal reveal mask geometry. It does not change routing APIs, hero zoom, system transitions, modal presentation, or the push/pop-only support boundary.

## Shared Axis Flow

For the selected axis, push uses these endpoints:

- Incoming: relative offset `+0.14`, scale `0.985`, opacity `0.0`.
- Outgoing: relative offset `-0.07`, scale `0.985`, opacity `0.58`.
- Horizontal uses the X axis and vertical uses the Y axis.
- Duration is `0.36` seconds with cubic timing `(0.22, 1.0, 0.36, 1.0)`.

Pop mirrors the push endpoints so both screens return along the same axis. The preset remains compatible with interactive pop and cancellation.

## Radial Reveal

Push uses these endpoints:

- Incoming: scale `1.025`, opacity `0.2`, and a reveal mask from the requested `UnitPoint`.
- Outgoing: scale `0.975`, opacity `0.78`.
- Duration is `0.42` seconds with cubic timing `(0.16, 1.0, 0.30, 1.0)`.

The reveal mask is a live circular `UIView` mask:

- Its center is the resolved pixel coordinate of the requested `UnitPoint` inside the transitioned view.
- Its radius is the distance from that center to the farthest view corner.
- At identity scale, the circle fully covers the view.
- At the reveal endpoint, its transform scale is `0.001`.
- The mask transform is animated by the existing `UIViewPropertyAnimator`, so transition progress, reverse pop, interactive completion, and cancellation use the same interruptible timeline.

Pop mirrors the endpoints. The outgoing destination contracts its radial mask back to the source point while the previous view returns from its subtle recessed state.

## Depth Dolly

Push uses these endpoints:

- Incoming: scale `1.09`, opacity `0.0`.
- Outgoing: scale `0.90`, opacity `0.42`.
- Duration is `0.40` seconds with cubic timing `(0.20, 0.80, 0.20, 1.0)`.

Pop mirrors the endpoints. The effect uses scale and opacity only; it does not introduce blur, snapshots, Core Image filters, or forced rasterization.

## Rendering and Restoration

- Continue using live `UIViewController` views.
- Preserve the existing transition hierarchy rules for push and pop.
- Restore the original view mask, transform, alpha, layer state, and interaction state after completion or cancellation.
- Circular masks are created only for reveal transitions and released with the managed transition view.
- The transition container retains its non-black system background behavior.

## Accessibility

When Reduce Motion is enabled, all three presets continue to compile to the existing `0.18` second fade-only descriptor. Offset, scale, and circular reveal masking are disabled in that mode.

## Testing

Automated tests will verify:

- Shared Axis horizontal and vertical endpoint vectors, scales, opacities, mirrored pop behavior, duration, and timing curve.
- Reveal incoming/outgoing scale and opacity, origin retention, mirrored pop behavior, duration, and timing curve.
- Circular reveal mask center, radius, square bounds, corner radius, small endpoint transform, and restoration of a pre-existing mask.
- Depth push and pop scales and opacities, duration, and timing curve.
- Reduce Motion removes all three presets' transforms and reveal masks.

Simulator QA will cover normal push, router pop, navigation-bar back, system dismiss, completed interactive pop, cancelled interactive pop, and repeated transitions on the latest runtime. Focused descriptor and animator tests will also run on iOS 16.

## Success Criteria

- Shared Axis reads as one cohesive content flow rather than a short slide transition.
- Reveal expands and contracts as a circle from the configured origin without rectangular edges or black frames.
- Depth clearly separates foreground and background without blur or snapshot cost.
- All three presets preserve view state and remain visually continuous during interactive cancellation.
