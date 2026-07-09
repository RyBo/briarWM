import Foundation

/// The single "can I trust the window server right now?" decision, pulled out of
/// `WindowManager` so it can be unit-tested without AppKit/AX. Foundation-only (it needs
/// `Date` for the mass-reap confirm window); no window-server calls of its own — callers
/// hand it what they read and act on the verdict.
///
/// Three states:
/// - **active** — normal; destructive reconcile (reap, rehome, sticky-float) allowed.
/// - **suspended** — displays are asleep; every liveness signal reads "gone" for windows
///   that are fine, so no reconcile runs at all.
/// - **settling** — entered on wake and whenever a census reads *every* window dead. The
///   non-destructive pass still runs (refresh spaces, adopt, pending restores, retile) but
///   reap/rehome/float are held until a census reads mostly-alive again. This rides out a
///   maintenance/Power-Nap wake of any length — windows never read alive during one, so the
///   gate stays in settling until a real wake lights the panel. A fixed grace period was
///   rejected because that length is unknown.
///
/// Every `suspend()`/`wake()` clears the primed mass-reap set, so a dead-read taken on one
/// side of a sleep can never confirm one taken on the other side (the overnight bug: a pass
/// before sleep primed a set that a pass four hours later after wake then "confirmed").
struct ReconcileGate {
    enum State: Equatable { case active, suspended, settling }
    enum CensusVerdict: Equatable { case reap, deferred, unreliable }

    private(set) var state: State = .active
    /// The window set a mass-reap is deferred for: everything reading dead at once is usually
    /// a transition artifact, believed only when the exact same set reads dead again inside
    /// `confirmWindow`.
    private(set) var pendingMassReap: Set<WinID> = []
    private var pendingMassReapAt: Date?
    /// How long a primed mass-reap stays confirmable. A pass separated from its prime by more
    /// than this is treated as unrelated — the continuity bound the old breaker lacked.
    let confirmWindow: TimeInterval

    init(confirmWindow: TimeInterval = 10) { self.confirmWindow = confirmWindow }

    /// Reconcile (the non-destructive pass) runs in every state except suspended.
    var allowsReconcile: Bool { state != .suspended }
    /// Reap/rehome/sticky-float run only when fully settled.
    var allowsDestructive: Bool { state == .active }

    /// Displays went to sleep. Clears any primed set so it can't confirm across the gap.
    /// Returns true only on a real transition (so the caller logs once).
    mutating func suspend() -> Bool {
        pendingMassReap = []
        pendingMassReapAt = nil
        guard state != .suspended else { return false }
        state = .suspended
        return true
    }

    /// The caller has verified a display is actually lit. Suspended → settling; the settle
    /// exits to active on the first mostly-alive census. Clears any primed set for the same
    /// reason `suspend()` does. Returns true only on a real transition.
    mutating func wake() -> Bool {
        pendingMassReap = []
        pendingMassReapAt = nil
        guard state == .suspended else { return false }
        state = .settling
        return true
    }

    /// Weigh a liveness census — `scanned` windows checked, `dead` the ones whose AX element
    /// is gone — and say what the reaper may do with it. `now` is injected so tests pin the
    /// confirm window to fixed dates.
    mutating func census(scanned: Int, dead: Set<WinID>, now: Date) -> CensusVerdict {
        let massDead = dead.count >= 2 && dead.count * 2 > scanned
        let allDead = dead.count >= 2 && dead.count == scanned

        switch state {
        case .suspended:
            return .unreliable                     // fail-safe; callers guard before reaching here

        case .settling:
            if massDead {                          // still garbage: hold the settle, drop any prime
                pendingMassReap = []
                return .unreliable
            }
            state = .active                        // a mostly-alive (or empty) pass ends the settle
            return activeVerdict(massDead: massDead, allDead: allDead, dead: dead, now: now)

        case .active:
            return activeVerdict(massDead: massDead, allDead: allDead, dead: dead, now: now)
        }
    }

    /// The active-state ruling, shared with the settle-exit path so a small dead set surfacing
    /// in the same healthy pass reaps normally.
    private mutating func activeVerdict(massDead: Bool, allDead: Bool,
                                        dead: Set<WinID>, now: Date) -> CensusVerdict {
        if allDead {
            // No user action makes *every* tracked window read dead while briarWM runs —
            // Cmd-Q arrives window-by-window via `removeApp`. Treat it as a window-server
            // transition, drop back to settling, never prime a confirm.
            state = .settling
            pendingMassReap = []
            return .unreliable
        }
        if massDead {
            // The genuine mass-missed-destroy backstop (Firefox): believe a partial mass-dead
            // set only when the same set was primed inside the confirm window.
            if pendingMassReap == dead, let at = pendingMassReapAt,
               now.timeIntervalSince(at) <= confirmWindow {
                pendingMassReap = []
                pendingMassReapAt = nil
                return .reap
            }
            pendingMassReap = dead
            pendingMassReapAt = now
            return .deferred
        }
        // Single / minority dead: real, reap immediately.
        pendingMassReap = []
        pendingMassReapAt = nil
        return .reap
    }
}
