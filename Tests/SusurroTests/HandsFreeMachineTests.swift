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
        #expect(m.state == .latched(since: 0))
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
        #expect(m.state == .latched(since: 0))
    }

    @Test func safetyWarningOnceThenStop() {
        var m = M(safetyLimit: 600, warningLead: 30)
        m.handle(.pttDown(at: 100)); m.handle(.latchDown(at: 101)); m.handle(.pttUp(at: 102))
        #expect(m.handle(.tick(at: 669)).effects.isEmpty)
        #expect(m.handle(.tick(at: 670)).effects == [.warnSafetyStop(remaining: 30)])
        #expect(m.handle(.tick(at: 680)).effects.isEmpty)
        #expect(m.handle(.tick(at: 700)).effects == [.stopAndInsert(reason: .safetyLimit)])
        #expect(m.state == .idle)
    }

    @Test func safetyStopWhileStillHoldingWaitsForRelease() {
        var m = M(safetyLimit: 10, warningLead: 0)
        m.handle(.pttDown(at: 0)); m.handle(.latchDown(at: 1))
        #expect(m.handle(.tick(at: 10)).effects.contains(.stopAndInsert(reason: .safetyLimit)))
        #expect(m.handle(.pttUp(at: 11)).effects.isEmpty)
        #expect(m.state == .idle)
    }

    @Test func noSafetyStopInHoldMode() {
        var m = M(safetyLimit: 10)
        m.handle(.pttDown(at: 0))
        #expect(m.handle(.tick(at: 1000)).effects.isEmpty)
        #expect(m.handle(.pttUp(at: 1001)).effects == [.stopAndInsert(reason: .released)])
    }

    @Test func warningResetsPerSession() {
        var m = M(safetyLimit: 100, warningLead: 10)
        m.handle(.pttDown(at: 0)); m.handle(.latchDown(at: 0)); m.handle(.pttUp(at: 0))
        #expect(!m.handle(.tick(at: 95)).effects.isEmpty)
        m.handle(.pttDown(at: 96)); m.handle(.pttUp(at: 96))
        m.handle(.pttDown(at: 200)); m.handle(.latchDown(at: 200)); m.handle(.pttUp(at: 200))
        #expect(m.handle(.tick(at: 291)).effects == [.warnSafetyStop(remaining: 9)])
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
