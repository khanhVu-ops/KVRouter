import UIKit
import XCTest
import KVRouterCore
@testable import KVRouterKit

@MainActor
final class KVHeroTransitionTests: XCTestCase {
    func testRegistryRejectsInvalidFrames() {
        let registry = KVTransitionSourceRegistry()

        registry.update(id: "zero", frame: .zero, view: nil)
        registry.update(
            id: "infinite",
            frame: CGRect(
                x: 0,
                y: 0,
                width: CGFloat.infinity,
                height: 20
            ),
            view: nil
        )

        XCTAssertNil(registry.source(for: "zero"))
        XCTAssertNil(registry.source(for: "infinite"))
    }

    func testRegistryDoesNotRetainSourceView() {
        let registry = KVTransitionSourceRegistry()
        var sourceView: UIView? = UIView(
            frame: CGRect(x: 20, y: 30, width: 80, height: 60)
        )
        let weakSource = KVWeakViewBox(sourceView!)
        registry.update(
            id: "card",
            frame: sourceView!.frame,
            view: sourceView
        )

        sourceView = nil

        XCTAssertNil(weakSource.view)
        XCTAssertNil(registry.source(for: "card"))
    }

    func testLiveSourceResolvesIntoTransitionContainerCoordinates() throws {
        let window = UIWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        let container = UIView(
            frame: CGRect(x: 10, y: 40, width: 370, height: 760)
        )
        let sourceView = UIView(
            frame: CGRect(x: 30, y: 50, width: 100, height: 80)
        )
        window.addSubview(container)
        window.addSubview(sourceView)
        let registry = KVTransitionSourceRegistry()
        registry.update(
            id: "card",
            frame: sourceView.convert(sourceView.bounds, to: window),
            view: sourceView,
            cornerRadius: 16
        )

        let geometry = try XCTUnwrap(
            registry.source(for: "card")?.resolved(in: container)
        )

        XCTAssertEqual(geometry.frame.origin.x, 20, accuracy: 0.001)
        XCTAssertEqual(geometry.frame.origin.y, 10, accuracy: 0.001)
        XCTAssertEqual(geometry.frame.size, sourceView.bounds.size)
        XCTAssertEqual(geometry.cornerRadius, 16)
    }

    func testHeroGeometryProducesScaleAndCenterTranslation() {
        let geometry = KVHeroTransitionGeometry(
            frame: CGRect(x: 20, y: 100, width: 100, height: 80),
            cornerRadius: 16
        )
        let resolved = geometry.resolvedState(
            for: CGRect(x: 0, y: 0, width: 400, height: 800)
        )

        XCTAssertEqual(resolved.scale.width, 0.25, accuracy: 0.001)
        XCTAssertEqual(resolved.scale.height, 0.1, accuracy: 0.001)
        XCTAssertEqual(resolved.translation.width, -130, accuracy: 0.001)
        XCTAssertEqual(resolved.translation.height, -260, accuracy: 0.001)
        XCTAssertFalse(CATransform3DIsIdentity(resolved.transform))
    }
}
