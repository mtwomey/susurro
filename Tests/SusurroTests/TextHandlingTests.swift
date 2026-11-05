import Foundation
import Testing
@testable import SusurroCore

/// Fixtures for the three BEA-647 symptoms plus the empty-field policy.
@Suite struct TextHandlingTests {
    let stage = TextHandlingStage.standard(smartSpacing: true, autoCapitalize: true)

    func ax(_ before: String?, after: String? = nil) -> InsertContext {
        InsertContext.resolve(fieldRead: FieldRead(before: before, after: after),
                              memoryTail: nil, pid: 42, bundleID: "com.example",
                              engine: .parakeet, secureInput: false)
    }

    // MARK: symptom 1 — stray leading space in an empty field

    @Test func emptyFieldAfterEnterToSendGetsNoLeadingSpace() {
        // Memory still holds the last message's tail (same pid), but the AX
        // read says the field is empty: Accessibility wins.
        let ctx = InsertContext.resolve(fieldRead: FieldRead(before: "", after: ""),
                                        memoryTail: "there.", pid: 42, bundleID: nil,
                                        engine: .whisper, secureInput: false)
        #expect(ctx.source == .accessibility)
        #expect(stage.apply("Next message.", ctx) == "Next message.")
    }

    @Test func unknownContextIsTreatedAsEmptyField() {
        #expect(stage.apply("hello there", .unknown) == "Hello there")
        #expect(stage.apply(" hello", .unknown) == "Hello")
    }

    // MARK: symptom 2 — double space after a user-typed space

    @Test func userTypedSpaceIsNotDoubled() {
        #expect(stage.apply("We should go", ax("I think ")) == "we should go")
        #expect(stage.apply("we should go", ax("I think\t")) == "we should go")
    }

    @Test func cleanupLeadingWhitespaceIsDropped() {
        #expect(stage.apply("  we should go", ax("I think ")) == "we should go")
        #expect(stage.apply("  we should go", ax("I think")) == " we should go")
    }

    // MARK: symptom 3 — capital letter on a continuation

    @Test func continuationIsLowerCased() {
        #expect(stage.apply("We should go", ax("I think")) == " we should go")
        #expect(stage.apply("We should go", ax("Well,")) == " we should go")
    }

    @Test func continuationKeepsPronounIAndInternalCapitals() {
        #expect(stage.apply("I agree", ax("and so")) == " I agree")
        #expect(stage.apply("I'm in", ax("and so")) == " I'm in")
        #expect(stage.apply("iOS is fine", ax("and")) == " iOS is fine")
        #expect(stage.apply("NASA called", ax("and")) == " NASA called")
        #expect(stage.apply("McDonald said", ax("and")) == " McDonald said")
    }

    @Test func afterSentenceEndCapitalises() {
        #expect(stage.apply("we should go", ax("Done.")) == " We should go")
        #expect(stage.apply("we should go", ax("Really? ")) == "We should go")
        #expect(stage.apply("we should go", ax("He said \"stop.\"")) == " We should go")
        #expect(stage.apply("we should go", ax("Line one\n")) == "We should go")
    }

    // MARK: leading-space rules

    @Test func noSpaceAfterOpenersOrBeforeAttachedPunctuation() {
        #expect(stage.apply("see above", ax("note (")) == "see above")
        #expect(stage.apply("hello", ax("she said \"")) == "hello")
        #expect(stage.apply("hello", ax("she said \"hi\"")) == " hello")
        #expect(stage.apply(", and more", ax("this")) == ", and more")
    }

    // MARK: context resolution

    @Test func memoryIsFallbackWhenAccessibilityUnreadable() {
        let ctx = InsertContext.resolve(fieldRead: FieldRead(before: nil), memoryTail: "go",
                                        pid: 1, bundleID: nil, engine: nil, secureInput: false)
        #expect(ctx.source == .selfTracked)
        #expect(stage.apply("And then", ctx) == " and then")
        let none = InsertContext.resolve(fieldRead: nil, memoryTail: nil,
                                         pid: 1, bundleID: nil, engine: nil, secureInput: false)
        #expect(none.source == .none)
        #expect(none.before == nil)
    }

    @Test func secureFieldYieldsNoContext() {
        let a = InsertContext.resolve(fieldRead: .secureField, memoryTail: "x",
                                      pid: 1, bundleID: nil, engine: nil, secureInput: false)
        let b = InsertContext.resolve(fieldRead: FieldRead(before: "abc"), memoryTail: "x",
                                      pid: 1, bundleID: nil, engine: nil, secureInput: true)
        #expect(a.secureInput && a.before == nil && a.source == .none)
        #expect(b.secureInput && b.before == nil && b.source == .none)
    }

    // MARK: toggles

    @Test func smartSpacingOffLeavesSpacingAndContinuationAlone() {
        let s = TextHandlingStage.standard(smartSpacing: false, autoCapitalize: true)
        #expect(s.apply("We should go", ax("I think")) == "We should go")
        #expect(s.apply("hello", .unknown) == "Hello")
    }

    @Test func autoCapitalizeOffNeverUpperCases() {
        let s = TextHandlingStage.standard(smartSpacing: true, autoCapitalize: false)
        #expect(s.apply("hello", .unknown) == "hello")
        #expect(s.apply("Hello", ax("so")) == " hello")
    }

    @Test func postProcessorCanDeferSentenceCase() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("th-rules-\(UUID().uuidString).json")
        let p = PostProcessor(userRulesURL: url)
        #expect(p.process("hello there", applySentenceCase: false).first == "h")
        #expect(p.process("hello there").first == "H")
        #expect(p.autoCapitalizeEnabled)
    }
}

@Suite struct FieldReadTests {
    @Test func caretPastValueEndMeansCollapsedTrailingSpace() {
        // Gecko reports "we left." but the caret sits after the typed space.
        let read = FieldRead.fromValue("we left.", location: 9, length: 0)
        #expect(read.before == "we left. ")
        let stage = TextHandlingStage.standard(smartSpacing: true, autoCapitalize: true)
        let ctx = InsertContext.resolve(fieldRead: read, memoryTail: nil, pid: 1,
                                        bundleID: nil, engine: nil, secureInput: false)
        #expect(stage.apply("it was late.", ctx) == "It was late.")
    }

    @Test func caretInsideValueSplitsBeforeAndAfter() {
        let read = FieldRead.fromValue("hello world", location: 5, length: 0)
        #expect(read.before == "hello")
        #expect(read.after == " world")
        #expect(!read.detail.contains("hello"))
    }
}

@Suite struct BufferTailTests {
    let stage = TextHandlingStage.standard(smartSpacing: true, autoCapitalize: true)

    func ctx(buffer: String, memory: String) -> InsertContext {
        InsertContext.resolve(fieldRead: FieldRead(before: nil, bufferTail: buffer),
                              memoryTail: memory, pid: 1, bundleID: "dev.warp.Warp-Stable",
                              engine: nil, secureInput: false)
    }

    @Test func deletedFullStopIsSeenInWarp() {
        let c = ctx(buffer: "$ echo\nHello there", memory: "Hello there.")
        #expect(c.source == .bufferTail)
        #expect(stage.apply("And then we left.", c) == " and then we left.")
    }

    @Test func typedSpaceIsSeenInWarp() {
        let c = ctx(buffer: "prompt> Hello there. ", memory: "Hello there.")
        #expect(stage.apply("it was late.", c) == "It was late.")
    }

    @Test func trailingNewlinesInBufferAreIgnored() {
        let c = ctx(buffer: "x Hello there\n\n", memory: "Hello there.")
        #expect(c.source == .bufferTail)
    }

    @Test func unrelatedBufferEndFallsBackToMemory() {
        let c = ctx(buffer: "lots of new output scrolled in here", memory: "Hello there.")
        #expect(c.source == .selfTracked)
        let far = ctx(buffer: "Hello there. plus much more typed", memory: "Hello there.")
        #expect(far.source == .selfTracked)
    }

    @Test func noMemoryMeansNoBufferContext() {
        let c = InsertContext.resolve(fieldRead: FieldRead(before: nil, bufferTail: "abc"),
                                      memoryTail: nil, pid: 1, bundleID: nil, engine: nil,
                                      secureInput: false)
        #expect(c.source == .none)
    }
}
