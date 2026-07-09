import Foundation
import Testing
@testable import briarWM

/// `ReconcileGate` is the pure "can I trust the window server right now?" state machine that
/// decides whether a liveness census may reap. The tricky cases are all continuity ones — a
/// mass-dead read must confirm only against a *recent* prime, and a prime must never survive a
/// sleep/wake transition (the overnight scramble bug).
@Suite struct ReconcileGateTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func w(_ ids: UInt...) -> Set<WinID> { Set(ids.map(WinID.init)) }

    @Test func startsActiveAndReapsMinorityDeadImmediately() {
        var gate = ReconcileGate()
        #expect(gate.state == .active)
        // One dead out of five: a real close, reap now.
        #expect(gate.census(scanned: 5, dead: w(1), now: t0) == .reap)
        // Two dead out of six is still a minority (2*2 <= 6): reap now.
        #expect(gate.census(scanned: 6, dead: w(1, 2), now: t0) == .reap)
        #expect(gate.state == .active)
    }

    @Test func partialMassDeadPrimesThenConfirmsSameSetInWindow() {
        var gate = ReconcileGate(confirmWindow: 10)
        // Four of six dead (a majority, not all): defer and prime.
        #expect(gate.census(scanned: 6, dead: w(1, 2, 3, 4), now: t0) == .deferred)
        #expect(gate.pendingMassReap == w(1, 2, 3, 4))
        // Same set 5s later: inside the window → reap, prime cleared.
        #expect(gate.census(scanned: 6, dead: w(1, 2, 3, 4), now: t0.addingTimeInterval(5)) == .reap)
        #expect(gate.pendingMassReap.isEmpty)
    }

    @Test func differentMassDeadSetRePrimes() {
        var gate = ReconcileGate(confirmWindow: 10)
        #expect(gate.census(scanned: 6, dead: w(1, 2, 3, 4), now: t0) == .deferred)
        // A different majority set arrives: re-prime, don't confirm the old one.
        #expect(gate.census(scanned: 6, dead: w(3, 4, 5, 6), now: t0.addingTimeInterval(2)) == .deferred)
        #expect(gate.pendingMassReap == w(3, 4, 5, 6))
    }

    @Test func staleMassDeadNeverConfirms() {
        var gate = ReconcileGate(confirmWindow: 10)
        #expect(gate.census(scanned: 6, dead: w(1, 2, 3, 4), now: t0) == .deferred)
        // Same set but past the confirm window: re-prime with the new time, still deferred.
        #expect(gate.census(scanned: 6, dead: w(1, 2, 3, 4), now: t0.addingTimeInterval(11)) == .deferred)
        #expect(gate.pendingMassReap == w(1, 2, 3, 4))
    }

    @Test func primeDoesNotSurviveSuspendWake() {
        // The exact overnight bug: a pre-sleep pass primes a set, then hours later a post-wake
        // pass reads the same set. The prime must have been cleared by suspend/wake so it can't
        // confirm — and the post-wake pass lands in settling, which reports unreliable anyway.
        var gate = ReconcileGate(confirmWindow: 10)
        // A partial mass-dead (5 of 6) primes without dropping to settling.
        #expect(gate.census(scanned: 6, dead: w(1, 2, 3, 4, 5), now: t0) == .deferred)
        #expect(gate.suspend() == true)
        #expect(gate.pendingMassReap.isEmpty)
        #expect(gate.wake() == true)
        #expect(gate.state == .settling)
        // Same set, four hours later: unreliable, never reaped.
        #expect(gate.census(scanned: 6, dead: w(1, 2, 3, 4, 5),
                            now: t0.addingTimeInterval(4 * 3600)) == .unreliable)
        #expect(gate.pendingMassReap.isEmpty)
    }

    @Test func allDeadInActiveEntersSettlingWithoutPriming() {
        var gate = ReconcileGate()
        // Every tracked window read dead: a transition, not a mass close. Enter settling.
        #expect(gate.census(scanned: 6, dead: w(1, 2, 3, 4, 5, 6), now: t0) == .unreliable)
        #expect(gate.state == .settling)
        #expect(gate.pendingMassReap.isEmpty)
    }

    @Test func settlingHoldsThroughGarbageThenExitsOnHealthyPass() {
        var gate = ReconcileGate()
        #expect(gate.census(scanned: 6, dead: w(1, 2, 3, 4, 5, 6), now: t0) == .unreliable)
        // Repeated all/mostly-dead censuses (the maintenance-wake garbage) keep it settling.
        #expect(gate.census(scanned: 6, dead: w(1, 2, 3, 4, 5, 6),
                            now: t0.addingTimeInterval(60)) == .unreliable)
        #expect(gate.census(scanned: 6, dead: w(1, 2, 3, 4),
                            now: t0.addingTimeInterval(120)) == .unreliable)
        #expect(gate.state == .settling)
        // A mostly-alive pass ends the settle; a small dead set in it reaps in the same pass.
        #expect(gate.census(scanned: 6, dead: w(1), now: t0.addingTimeInterval(180)) == .reap)
        #expect(gate.state == .active)
    }

    @Test func settlingExitsOnEmptyScan() {
        var gate = ReconcileGate()
        #expect(gate.census(scanned: 6, dead: w(1, 2, 3, 4, 5, 6), now: t0) == .unreliable)
        // Nothing to scan (all trees emptied) also ends the settle — nothing to defer.
        #expect(gate.census(scanned: 0, dead: [], now: t0.addingTimeInterval(30)) == .reap)
        #expect(gate.state == .active)
    }

    @Test func suspendedAlwaysUnreliable() {
        var gate = ReconcileGate()
        #expect(gate.suspend() == true)
        #expect(gate.census(scanned: 5, dead: w(1), now: t0) == .unreliable)
        #expect(gate.allowsReconcile == false)
        #expect(gate.allowsDestructive == false)
    }

    @Test func transitionsReturnTrueOnlyOnRealChange() {
        var gate = ReconcileGate()
        #expect(gate.suspend() == true)     // active → suspended
        #expect(gate.suspend() == false)    // already suspended
        #expect(gate.wake() == true)        // suspended → settling
        #expect(gate.wake() == false)       // not suspended
    }

    @Test func settlingAllowsReconcileButNotDestructive() {
        var gate = ReconcileGate()
        _ = gate.suspend()
        _ = gate.wake()
        #expect(gate.state == .settling)
        #expect(gate.allowsReconcile == true)
        #expect(gate.allowsDestructive == false)
    }

    /// The full overnight replay from the plan: prime → sleep → maintenance wake → repeated
    /// garbage → sleep again → real morning wake → healthy pass. Assert no `.reap` ever came
    /// back over the mass sets — the layout is never destroyed.
    @Test func overnightReplayNeverReapsTheMassSets() {
        var gate = ReconcileGate(confirmWindow: 10)
        var reaped: [ReconcileGate.CensusVerdict] = []

        // 23:51 — poll reads all-dead garbage just before the sleep notification.
        let pre = gate.census(scanned: 6, dead: w(1, 2, 3, 4, 5, 6), now: t0)
        reaped.append(pre)
        #expect(pre == .unreliable)                       // all-dead → settling, not primed

        // 23:51 — displays sleep.
        #expect(gate.suspend() == true)

        // 03:58 — maintenance/Power-Nap wake; caller verified a lit display.
        #expect(gate.wake() == true)

        // 03:58–03:59 — post-wake passes still read the re-adopted windows dead.
        for minute in 0...3 {
            let v = gate.census(scanned: 6, dead: w(8, 9, 10, 11, 12, 13),
                                now: t0.addingTimeInterval(4 * 3600 + Double(minute) * 60))
            reaped.append(v)
            #expect(v == .unreliable)
        }

        // External displays detach and re-attach: suspend + wake again.
        #expect(gate.suspend() == true)
        #expect(gate.wake() == true)

        // 13:21 — real user wake, windows finally read alive.
        let morning = gate.census(scanned: 6, dead: [], now: t0.addingTimeInterval(13 * 3600))
        #expect(morning == .reap)                         // empty reap set — nothing destroyed
        #expect(gate.state == .active)

        // Not once did a `.reap` verdict carry a mass set.
        #expect(!reaped.contains(.reap))
    }
}
