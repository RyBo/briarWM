import Testing
import Foundation
@testable import briarWM

@Suite struct HexColorTests {

    /// Compare components with a small tolerance (the 0…255 → 0…1 division isn't exact).
    private func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func parsesSixDigit() throws {
        let c = try #require(HexColor(hex: "#22D3EE"))
        #expect(approx(c.r, 0x22 / 255))
        #expect(approx(c.g, 0xD3 / 255))
        #expect(approx(c.b, 0xEE / 255))
        #expect(c.a == 1)
    }

    @Test func leadingHashIsOptional() {
        #expect(HexColor(hex: "22D3EE") == HexColor(hex: "#22D3EE"))
    }

    @Test func parsesShorthand() throws {
        // #F0A expands to #FF00AA — each nibble doubled.
        let short = try #require(HexColor(hex: "#F0A"))
        let long = try #require(HexColor(hex: "#FF00AA"))
        #expect(short == long)
    }

    @Test func parsesEightDigitAlpha() throws {
        let c = try #require(HexColor(hex: "#22D3EE80"))
        #expect(approx(c.a, 0x80 / 255))
    }

    @Test func parsesFourDigitAlphaShorthand() throws {
        let short = try #require(HexColor(hex: "#F0A8"))
        let long = try #require(HexColor(hex: "#FF00AA88"))
        #expect(short == long)
    }

    @Test func rejectsMalformed() {
        #expect(HexColor(hex: "#XYZ") == nil)       // non-hex digits
        #expect(HexColor(hex: "#12345") == nil)     // wrong length (5)
        #expect(HexColor(hex: "#") == nil)          // empty
        #expect(HexColor(hex: "22D3E") == nil)      // wrong length (5), no hash
    }

    @Test func decodesFromJSONString() throws {
        struct Box: Decodable { let color: HexColor }
        let box = try JSONDecoder().decode(Box.self, from: Data(##"{ "color": "#22D3EE" }"##.utf8))
        #expect(box.color == HexColor(hex: "#22D3EE"))
    }

    @Test func decodeThrowsOnMalformed() {
        struct Box: Decodable { let color: HexColor }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Box.self, from: Data(#"{ "color": "nope" }"#.utf8))
        }
    }
}
