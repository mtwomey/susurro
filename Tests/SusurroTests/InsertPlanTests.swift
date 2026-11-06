import Foundation
import Testing
@testable import SusurroCore

struct InsertPlanTests {
    private let stage = TextHandlingStage.standard(smartSpacing: true, autoCapitalize: true)
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func appSwitchCopiesWithHeldMark() {
        let join = InsertPlan.Join(joinedText: ". Next part", previousBody: "First", previousShown: false,
                                   previousMark: ".", decision: .sentenceBreak)
        let plan = InsertPlan.make(processed: "Next part", join: join, isHandsFree: true, expectedPID: 1, frontmostPID: 2,
                                   context: InsertContext(before: nil, source: .none), stage: stage, secureInput: false,
                                   heldMark: nil, cross: nil, startedAt: now, fieldValue: nil)
        #expect(plan.action == .clipboardAfterAppSwitch(text: ". Next part"))
        #expect(InsertPlan.appSwitchClipboardText(processed: "Next part",
                                                  join: .init(joinedText: ". Next part", previousShown: true)) == "Next part")
    }

    @Test func plainDictationGoesThroughTextStage() {
        let ctx = InsertContext(before: "Hello there.", after: "", source: .accessibility)
        let plan = InsertPlan.make(processed: "general kenobi", join: .init(), isHandsFree: false, expectedPID: nil,
                                   frontmostPID: 1, context: ctx, stage: stage, secureInput: false,
                                   heldMark: nil, cross: nil, startedAt: now, fieldValue: nil)
        #expect(plan.action == .insert(text: stage.apply("general kenobi", ctx), deleteBackward: 0))
        #expect(!plan.markShown && plan.crossLog.isEmpty)
    }

    @Test func handsFreeJoinInPlaceAndMovedCursor() {
        let join = InsertPlan.Join(joinedText: " move it", previousBody: "we should", previousShown: false,
                                   previousMark: ".", decision: .continuation)
        let inPlace = InsertPlan.make(processed: "Move it", join: join, isHandsFree: true, expectedPID: 1, frontmostPID: 1,
                                      context: InsertContext(before: nil, source: .none), stage: stage, secureInput: false,
                                      heldMark: nil, cross: nil, startedAt: now, fieldValue: nil)
        #expect(inPlace.action == .insert(text: " move it", deleteBackward: 0))
        let moved = InsertPlan.make(processed: "Move it", join: join, isHandsFree: true, expectedPID: 1, frontmostPID: 1,
                                    context: InsertContext(before: "something else", after: "", source: .accessibility),
                                    stage: stage, secureInput: false, heldMark: ".", cross: nil, startedAt: now, fieldValue: nil)
        #expect(moved.notes == ["handsfree: cursor moved, join skipped"])
        // Readable field: this piece's own held mark is shown.
        #expect(moved.markShown)
        if case .insert(let text, _) = moved.action { #expect(text.hasSuffix(".")) }
    }
}
