//
//  KVTransitionSourceTests.swift
//  KVRouterKit
//

import Testing
import UIKit
@testable import KVRouterKit

@MainActor
@Suite("Transition source")
struct KVTransitionSourceTests {

    /// SwiftUI's `clipShape` and `cornerRadius` never reach `layer.cornerRadius`,
    /// so measuring the layer reported 0 for a visibly rounded card and the hero
    /// animation landed on square corners. The caller's value has to win.
    @Test("An explicit corner radius beats the layer's")
    func explicitCornerRadiusWins() {
        let registry = KVTransitionSourceRegistry()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 90))
        view.layer.cornerRadius = 0

        registry.update(id: "card", frame: view.frame, view: view, cornerRadius: 24)

        #expect(registry.source(for: "card")?.cornerRadius == 24)
    }

    @Test("Falls back to the layer when no radius is given")
    func fallsBackToTheLayer() {
        let registry = KVTransitionSourceRegistry()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 90))
        view.layer.cornerRadius = 8

        registry.update(id: "card", frame: view.frame, view: view, cornerRadius: nil)

        #expect(registry.source(for: "card")?.cornerRadius == 8)
    }

    @Test("Native identity rotates only when a zoom pop completes")
    func nativeIdentityRotatesAfterPop() {
        let registry = KVTransitionSourceRegistry()
        let first = registry.nativeSourceID(for: "card")

        #expect(registry.nativeSourceID(for: "card") == first)

        registry.resetNativeSource(id: "card")
        let second = registry.nativeSourceID(for: "card")

        #expect(second != first)
        #expect(registry.nativeSourceID(for: "card") == second)
    }

    /// Two sources trading ids is a supported move — a paged viewer hands its zoom identity to
    /// whichever thumbnail is now on screen — and SwiftUI runs the old subtrees' `onDisappear`
    /// *after* the new ones have registered. Removing by id alone therefore deleted the entry the
    /// other source had just written, and the next zoom silently became a fade.
    @Test("A source cannot remove an id another source now owns")
    func teardownCannotRemoveAnotherOwnersEntry() {
        let registry = KVTransitionSourceRegistry()
        let first = KVTransitionSourceOwner()
        let second = KVTransitionSourceOwner()
        let frame = CGRect(x: 0, y: 0, width: 120, height: 90)

        // `second` adopts the id `first` used to hold, then `first` tears its old subtree down.
        registry.update(id: "photo", frame: frame, view: nil, cornerRadius: 4, owner: second)
        registry.remove(id: "photo", owner: first)

        #expect(registry.source(for: "photo")?.cornerRadius == 4)
    }

    @Test("A source still removes the entry it owns")
    func teardownRemovesItsOwnEntry() {
        let registry = KVTransitionSourceRegistry()
        let owner = KVTransitionSourceOwner()
        let frame = CGRect(x: 0, y: 0, width: 120, height: 90)

        registry.update(id: "photo", frame: frame, view: nil, cornerRadius: 4, owner: owner)
        registry.remove(id: "photo", owner: owner)

        #expect(registry.source(for: "photo") == nil)
    }

    /// A cell that has not been laid out yet measures zero. Without the ownership check that
    /// measurement cleared whatever the id currently pointed at, which during a trade is the
    /// other cell's perfectly good geometry.
    @Test("An unmeasured source cannot clear another owner's geometry")
    func invalidFrameCannotClearAnotherOwnersEntry() {
        let registry = KVTransitionSourceRegistry()
        let measured = KVTransitionSourceOwner()
        let unmeasured = KVTransitionSourceOwner()

        registry.update(
            id: "photo",
            frame: CGRect(x: 0, y: 0, width: 120, height: 90),
            view: nil,
            cornerRadius: 4,
            owner: measured
        )
        registry.update(id: "photo", frame: .zero, view: nil, cornerRadius: 4, owner: unmeasured)

        #expect(registry.source(for: "photo")?.cornerRadius == 4)
    }

    /// A source answers to one logical ID at a time. When a caller moves an ID, the entry the
    /// source used to hold has to go with it — otherwise the old ID still resolves to a view that
    /// has started answering to another, and the zoom grows from the wrong cell.
    @Test("Registering a new id releases the one that source used to hold")
    func registeringReleasesThePreviousID() {
        let registry = KVTransitionSourceRegistry()
        let owner = KVTransitionSourceOwner()
        let frame = CGRect(x: 0, y: 0, width: 120, height: 90)

        registry.update(id: "before", frame: frame, view: nil, cornerRadius: 4, owner: owner)
        registry.update(id: "after", frame: frame, view: nil, cornerRadius: 4, owner: owner)

        #expect(registry.source(for: "before") == nil)
        #expect(registry.source(for: "after")?.cornerRadius == 4)
    }

    /// The release must not reach into an entry the other source has already claimed, which is
    /// exactly what happens when two cells trade IDs in one update.
    @Test("Two sources trading ids end up holding one entry each")
    func tradingIDsLeavesBothRegistered() {
        let registry = KVTransitionSourceRegistry()
        let first = KVTransitionSourceOwner()
        let second = KVTransitionSourceOwner()
        let frame = CGRect(x: 0, y: 0, width: 120, height: 90)

        registry.update(id: "photo", frame: frame, view: nil, cornerRadius: 4, owner: first)
        registry.update(id: "copy", frame: frame, view: nil, cornerRadius: 6, owner: second)

        // The trade: each adopts the other's ID, then each tears its old subtree down.
        registry.update(id: "copy", frame: frame, view: nil, cornerRadius: 4, owner: first)
        registry.update(id: "photo", frame: frame, view: nil, cornerRadius: 6, owner: second)
        registry.remove(id: "photo", owner: first)
        registry.remove(id: "copy", owner: second)

        #expect(registry.source(for: "photo")?.cornerRadius == 6)
        #expect(registry.source(for: "copy")?.cornerRadius == 4)
    }

    /// The hero animation scales the destination down onto the source, so the
    /// radius has to be divided by that scale or it shrinks with the view and
    /// reads as a squarer corner than the source has.
    @Test("Corner radius is compensated for the hero scale")
    func cornerRadiusCompensatesForScale() {
        let geometry = KVHeroTransitionGeometry(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            cornerRadius: 24
        )

        let resolved = geometry.resolvedState(
            for: CGRect(x: 0, y: 0, width: 400, height: 400)
        )

        #expect(resolved.cornerRadius == 24)
        #expect(abs(resolved.scale.width - 0.25) < 0.0001)
    }
}
