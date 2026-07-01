import Testing
import Carbon.HIToolbox
@testable import briarWM

@Suite struct KeycodesTests {

    @Test func parsesLetterWithModifiers() {
        let kc = KeyCombo.parse("alt+shift+h", defaultMod: "alt")
        #expect(kc?.keyCode == UInt32(kVK_ANSI_H))
        #expect(kc?.modifiers == UInt32(optionKey | shiftKey))
    }

    @Test func modTokenResolvesToDefault() {
        let cmd = KeyCombo.parse("$mod+return", defaultMod: "cmd")
        #expect(cmd?.modifiers == UInt32(cmdKey))
        #expect(cmd?.keyCode == UInt32(kVK_Return))
        let alt = KeyCombo.parse("mod+return", defaultMod: "alt")
        #expect(alt?.modifiers == UInt32(optionKey))
    }

    @Test func arrowsAndHyper() {
        #expect(KeyCombo.parse("alt+ctrl+left", defaultMod: "alt")?.keyCode == UInt32(kVK_LeftArrow))
        let hyper = KeyCombo.parse("hyper+space", defaultMod: "alt")
        #expect(hyper?.modifiers == UInt32(cmdKey | optionKey | controlKey | shiftKey))
    }

    @Test func unknownKeyReturnsNil() {
        #expect(KeyCombo.parse("alt+nonsense", defaultMod: "alt") == nil)
        #expect(KeyCombo.parse("", defaultMod: "alt") == nil)
    }

    @Test func twoKeyTokensAreRejected() {
        // Not "last key wins" — a malformed combo must fail so the validator reports it.
        #expect(KeyCombo.parse("alt+h+l", defaultMod: "alt") == nil)
    }

    @Test func modifierOnlyComboIsRejected() {
        #expect(KeyCombo.parse("alt+shift", defaultMod: "alt") == nil)
        #expect(KeyCombo.parse("shift", defaultMod: "alt") == nil)
    }
}
