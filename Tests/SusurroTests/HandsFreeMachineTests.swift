import Testing
@testable import SusurroCore

@Suite struct HandsFreeMachineTests {
    typealias M = HandsFreeMachine

    @Test func holdToTalkUnchanged() {
        var m = M()
        #expect(m.handle(.pttDown(at: 0)).effects == [.startRecording])
        #expect(m.isRecording && !m.isHandsFree)
        #expect(m.handle(.pttUp(at: 2)).effects == [.stopAndInsert(reason: .released)])
        #expect(m.state == .idle)
    }

    @Test func holdToTalkIgnoresEscAndLatchKeyWhenIdle() {
        var m = M()
        let esc = m.handle(.escape(at: 0))
        #expect(esc.effects.isEmpty && !esc.swallow)
        #expect(m.handle(.latchDown(at: 0)).effects.isEmpty)
        #expect(m.state == .idle)
    }

    @Test func escWhileHoldingPassesThrough() {
        var m = M()
        m.handle(.pttDown(at: 0))
        let out = m.handle(.escape(at: 1))
        #expect(out.effects.isEmpty && !out.swallow)
        #expect(m.handle(.pttUp(at: 2)).effects == [.stopAndInsert(reason: .released)])
    }

    @Test func latchThenReleaseKeepsRecording() {
        var m = M()
        m.handle(.pttDown(at: 0))
        #expect(m.handle(.latchDown(at: 1)).effects == [.latched])
        #expect(m.isHandsFree)
        #expect(m.handle(.pttUp(at: 1.5)).effects.isEmpty)
        #expect(m.state == .latched(since: 0, lastSpeech: 1))
        #expect(m.isRecording && m.isHandsFree)
    }

    @Test func tapPTTStopsAndInsertsOnPressAndIgnoresRelease() {
        var m = M()
        m.handle(.pttDown(at: 0)); m.handle(.latchDown(at: 1)); m.handle(.pttUp(at: 2))
        #expect(m.handle(.pttDown(at: 30)).effects == [.stopAndInsert(reason: .tapped)])
        #expect(!m.isRecording)
        #expect(m.handle(.pttUp(at: 30.1)).effects.isEmpty)
        #expect(m.state == .idle)
        // Next hold works as today.
        #expect(m.handle(.pttDown(at: 40)).effects == [.startRecording])
    }

    @Test func escDiscardsAndIsSwallowedOnlyWhenLatched() {
        var m = M()
        m.handle(.pttDown(at: 0)); m.handle(.latchDown(at: 1)); m.handle(.pttUp(at: 2))
        let out = m.handle(.escape(at: 5))
        #expect(out.effects == [.cancel] && out.swallow)
        #expect(m.state == .idle)
        #expect(!m.handle(.escape(at: 6)).swallow)
    }

    @Test func escWhileLatchedAndStillHoldingWaitsForRelease() {
        var m = M()
        m.handle(.pttDown(at: 0)); m.handle(.latchDown(at: 1))
        #expect(m.handle(.escape(at: 2)).effects == [.cancel])
        #expect(m.handle(.pttUp(at: 3)).effects.isEmpty)
        #expect(m.state == .idle)
    }

    @Test func repeatedLatchTapIsHarmless() {
        var m = M()
        m.handle(.pttDown(at: 0)); m.handle(.latchDown(at: 1)); m.handle(.pttUp(at: 2))
        #expect(m.handle(.latchDown(at: 3)).effects.isEmpty)
        #expect(m.state == .latched(since: 0, lastSpeech: 1))
    }

    @Test func defaultsMatchBoard() {
        let m = M()
        #expect(m.safetyLimit == 7_200 && m.idleLimit == 60)
    }

    /// Latch at t=0 and release; speech is reported every `speechEvery` s.
    static func latched(_ m: inout M) {
        m.handle(.pttDown(at: 0)); m.handle(.latchDown(at: 0)); m.handle(.pttUp(at: 0))
    }

    @Test func idleWarningThenStop() {
        var m = M(safetyLimit: 7_200, idleLimit: 60, warningLead: 10)
        Self.latched(&m)
        m.handle(.heardSpeech(at: 20))
        #expect(m.handle(.tick(at: 69)).effects.isEmpty)
        #expect(m.handle(.tick(at: 70)).effects == [.warnAutoStop(reason: .idle, remaining: 10)])
        #expect(m.handle(.tick(at: 75)).effects.isEmpty)
        #expect(m.handle(.tick(at: 80)).effects == [.stopAndInsert(reason: .idle)])
        #expect(m.state == .idle)
    }

    @Test func speechResetsIdleTimerAndWarning() {
        var m = M(safetyLimit: 7_200, idleLimit: 60, warningLead: 10)
        Self.latched(&m)
        #expect(!m.handle(.tick(at: 50)).effects.isEmpty) // warned
        m.handle(.heardSpeech(at: 55))
        #expect(m.handle(.tick(at: 100)).effects.isEmpty)
        #expect(m.handle(.tick(at: 105)).effects == [.warnAutoStop(reason: .idle, remaining: 10)])
    }

    @Test func safetyLimitStopsEvenWhileTalking() {
        var m = M(safetyLimit: 7_200, idleLimit: 60, warningLead: 10)
        Self.latched(&m)
        var t = 0.0
        var warnedSafety = false
        while t < 7_190 { t += 30; m.handle(.heardSpeech(at: t)); if t >= 7_190 { break }; _ = m.handle(.tick(at: t)) }
        let w = m.handle(.tick(at: 7_190))
        warnedSafety = w.effects.contains(.warnAutoStop(reason: .safetyLimit, remaining: 10))
        #expect(warnedSafety)
        m.handle(.heardSpeech(at: 7_199))
        #expect(m.handle(.tick(at: 7_200)).effects == [.stopAndInsert(reason: .safetyLimit)])
    }

    @Test func safetyStopWhileStillHoldingWaitsForRelease() {
        var m = M(safetyLimit: 10, idleLimit: 60, warningLead: 0)
        m.handle(.pttDown(at: 0)); m.handle(.latchDown(at: 1)); m.handle(.heardSpeech(at: 9))
        #expect(m.handle(.tick(at: 10)).effects.contains(.stopAndInsert(reason: .safetyLimit)))
        #expect(m.handle(.pttUp(at: 11)).effects.isEmpty)
        #expect(m.state == .idle)
    }

    @Test func noAutoStopInHoldMode() {
        var m = M(safetyLimit: 10, idleLimit: 5)
        m.handle(.pttDown(at: 0))
        #expect(m.handle(.tick(at: 1000)).effects.isEmpty)
        #expect(m.handle(.pttUp(at: 1001)).effects == [.stopAndInsert(reason: .released)])
    }

    @Test func appSwitchStopsHandsFreeOnly() {
        var m = M()
        m.handle(.pttDown(at: 0))
        #expect(m.handle(.appSwitched(at: 1)).effects.isEmpty) // hold mode: unchanged
        m.handle(.latchDown(at: 2)); m.handle(.pttUp(at: 3))
        #expect(m.handle(.appSwitched(at: 4)).effects == [.stopAndInsert(reason: .appSwitched)])
        #expect(m.state == .idle)
    }

    @Test func appSwitchWhileStillHoldingWaitsForRelease() {
        var m = M()
        m.handle(.pttDown(at: 0)); m.handle(.latchDown(at: 1))
        #expect(m.handle(.appSwitched(at: 2)).effects == [.stopAndInsert(reason: .appSwitched)])
        #expect(m.handle(.pttUp(at: 3)).effects.isEmpty)
        #expect(m.state == .idle)
    }

    @Test func resetReturnsToIdle() {
        var m = M()
        m.handle(.pttDown(at: 0)); m.handle(.latchDown(at: 1))
        m.reset()
        #expect(m.state == .idle)
        #expect(m.handle(.pttDown(at: 2)).effects == [.startRecording])
    }
}

@Suite struct LatchKeyResolverTests {
    @Test func defaultIsRightCommand() {
        #expect(LatchKeyResolver.resolve(ptt: "rightOption", preferred: nil) == "rightCommand")
        #expect(LatchKeyResolver.resolve(ptt: "rightControl", preferred: nil) == "rightCommand")
    }

    @Test func neverEqualsPTT() {
        for ptt in LatchKeyResolver.candidates {
            for pref in LatchKeyResolver.candidates + [nil, "bogus"] {
                #expect(LatchKeyResolver.resolve(ptt: ptt, preferred: pref) != ptt)
            }
        }
    }

    @Test func rightCommandPTTFallsBackToRightOption() {
        #expect(LatchKeyResolver.resolve(ptt: "rightCommand", preferred: nil) == "rightOption")
        #expect(LatchKeyResolver.resolve(ptt: "rightCommand", preferred: "rightCommand") == "rightOption")
        #expect(LatchKeyResolver.resolve(ptt: "rightCommand", preferred: "rightControl") == "rightControl")
    }

    @Test func choicesExcludePTT() {
        #expect(LatchKeyResolver.choices(ptt: "rightControl") == ["rightCommand", "rightOption"])
    }
}
