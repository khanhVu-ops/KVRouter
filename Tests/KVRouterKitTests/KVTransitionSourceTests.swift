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
