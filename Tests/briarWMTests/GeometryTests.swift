import Testing
import Foundation
@testable import briarWM

@Suite struct GeometryTests {

    @Test func roundTripPrimary() {
        let h: CGFloat = 1080
        let cocoa = CGRect(x: 100, y: 200, width: 400, height: 300)
        let ax = Geometry.cocoaToAX(cocoa, primaryHeight: h)
        #expect(approx(ax.minX, 100))
        #expect(approx(ax.minY, h - cocoa.maxY))     // top = H - cocoa.maxY
        #expect(rectApprox(Geometry.axToCocoa(ax, primaryHeight: h), cocoa))
    }

    @Test func secondaryDisplayNegativeOrigin() {
        let h: CGFloat = 1080
        let cocoa = CGRect(x: -1920, y: 0, width: 1920, height: 1200)
        let ax = Geometry.cocoaToAX(cocoa, primaryHeight: h)
        #expect(approx(ax.minX, -1920))              // negative X preserved
        #expect(rectApprox(Geometry.axToCocoa(ax, primaryHeight: h), cocoa))
    }

    @Test func pointConversion() {
        let h: CGFloat = 900
        let p = CGPoint(x: 50, y: 100)
        let ax = Geometry.cocoaToAX(p, primaryHeight: h)
        #expect(approx(ax.y, 800))
        #expect(approx(Geometry.axToCocoa(ax, primaryHeight: h).y, 100))
    }
}
