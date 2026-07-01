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
}
