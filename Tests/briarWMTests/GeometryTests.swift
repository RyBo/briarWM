import Testing
import Foundation
@testable import briarWM

@Suite struct GeometryTests {

    @Test func flipsAroundPrimaryHeight() {
        let h: CGFloat = 1080
        let cocoa = CGRect(x: 100, y: 200, width: 400, height: 300)
        let ax = Geometry.cocoaToAX(cocoa, primaryHeight: h)
        #expect(approx(ax.minX, 100))
        #expect(approx(ax.minY, h - cocoa.maxY))     // top = H - cocoa.maxY
        #expect(approx(ax.width, 400) && approx(ax.height, 300))
    }

    @Test func transformIsItsOwnInverse() {
        let h: CGFloat = 1080
        for rect in [CGRect(x: 100, y: 200, width: 400, height: 300),
                     CGRect(x: -1920, y: 0, width: 1920, height: 1200)] {   // secondary display
            let twice = Geometry.cocoaToAX(Geometry.cocoaToAX(rect, primaryHeight: h), primaryHeight: h)
            #expect(rectApprox(twice, rect))
        }
    }

    @Test func hudOriginCentersAboveBottom() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let size = CGSize(width: 200, height: 40)
        let origin = Geometry.hudOrigin(size: size, visibleFrame: visible, bottomOffset: 120)
        #expect(approx(origin.x, visible.midX - size.width / 2))   // horizontally centered
        #expect(approx(origin.y, 120))                             // offset above the bottom edge
    }

    @Test func hudOriginRespectsSecondaryDisplayFrame() {
        // A secondary display whose visible frame doesn't start at the origin.
        let visible = CGRect(x: -1920, y: 300, width: 1920, height: 1200)
        let size = CGSize(width: 240, height: 44)
        let origin = Geometry.hudOrigin(size: size, visibleFrame: visible, bottomOffset: 100)
        #expect(approx(origin.x, visible.midX - size.width / 2))
        #expect(approx(origin.y, 400))                             // minY (300) + offset (100)
    }
}
