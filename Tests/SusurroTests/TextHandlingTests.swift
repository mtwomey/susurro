import Foundation

/// A native text field with the caret between `before` and `after`.
func caretSnapshot(_ before: String, _ after: String) -> FieldSnapshot {
    FieldSnapshot(value: before + after,
                  selection: NSRange(location: (before as NSString).length, length: 0),
                  role: "AXTextField")
}
import Testing
@testable import SusurroCore

/// Fixtures for the three BEA-647 symptoms plus the empty-field policy.
@Suite struct TextHandlingTests {
    let stage = TextHandlingStage.standard(smartSpacing: true, autoCapitalize: true)

    func ax(_ before: String?, after: String? = nil) -> InsertContext {
        InsertContext.resolve(snapshot: before.map { caretSnapshot($0, after ?? "") },
                              memoryTail: nil, pid: 42, bundleID: "com.example",
                              engine: .parakeet, secureInput: false).0
    }

    // MARK: symptom 1 — stray leading space in an empty field

    @Test func emptyFieldAfterEnterToSendGetsNoLeadingSpace() {
        // Memory still holds the last message's tail (same pid), but the AX
        // read says the field is empty: Accessibility wins.
        let ctx = InsertContext.resolve(snapshot: FieldSnapshot(value: "", role: "AXTextArea"),
                                        memoryTail: "there.", pid: 42, bundleID: nil,
                                        engine: .whisper, secureInput: false).0
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
        let ctx = InsertContext.resolve(snapshot: .nothing, memoryTail: "go",
                                        pid: 1, bundleID: nil, engine: nil, secureInput: false).0
        #expect(ctx.source == .selfTracked)
        #expect(stage.apply("And then", ctx) == " and then")
        let none = InsertContext.resolve(snapshot: nil, memoryTail: nil,
                                         pid: 1, bundleID: nil, engine: nil, secureInput: false).0
        #expect(none.source == .none)
        #expect(none.before == nil)
    }

    @Test func secureFieldYieldsNoContext() {
        let a = InsertContext.resolve(snapshot: .secureField, memoryTail: "x",
                                      pid: 1, bundleID: nil, engine: nil, secureInput: false).0
        let b = InsertContext.resolve(snapshot: caretSnapshot("abc", ""), memoryTail: "x",
                                      pid: 1, bundleID: nil, engine: nil, secureInput: true).0
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

@Suite struct ContextProviderTests {
    let stage = TextHandlingStage.standard(smartSpacing: true, autoCapitalize: true)

    func resolve(_ snap: FieldSnapshot?, memory: String?) -> (InsertContext, String) {
        InsertContext.resolve(snapshot: snap, memoryTail: memory, pid: 1, bundleID: nil,
                              engine: nil, secureInput: false)
    }

    // Selection range (native fields, Gecko)

    @Test func caretPastValueEndMeansCollapsedTrailingSpace() {
        let snap = FieldSnapshot(value: "we left.", selection: NSRange(location: 9, length: 0))
        let (c, p) = resolve(snap, memory: nil)
        #expect(p == "selectionRange")
        #expect(c.before == "we left. ")
        #expect(stage.apply("it was late.", c) == "It was late.")
    }

    @Test func caretInsideValueSplitsBeforeAndAfter() {
        let (c, _) = resolve(caretSnapshot("hello", " world"), memory: nil)
        #expect(c.before == "hello")
        #expect(c.after == " world")
    }

    @Test func snapshotDetailCarriesNoText() {
        let snap = FieldSnapshot(value: "secret words", selection: NSRange(location: 3, length: 0),
                                 markerBefore: "sec", role: "AXTextArea")
        #expect(!snap.detail.contains("secret"))
        #expect(!snap.detail.contains("sec "))
        #expect(snap.detail.contains("valueLen=12"))
    }

    // Text markers

    @Test func markersMustBeAPrefixOfTheValue() {
        let ok = FieldSnapshot(value: "draft text", markerBefore: "draft")
        #expect(resolve(ok, memory: nil).1 == "textMarkers")
        let doc = FieldSnapshot(value: "draft text", markerBefore: "Page title draft")
        #expect(resolve(doc, memory: "xyz").1 == "memory")
    }

    // Anchored value: terminals (cursor at the end)

    func buffer(_ v: String) -> FieldSnapshot { FieldSnapshot(value: v, role: "AXTextArea") }

    @Test func terminalDeletedFullStop() {
        let (c, p) = resolve(buffer("$ echo\nHello there"), memory: "Hello there.")
        #expect(p == "anchoredValue.end")
        #expect(stage.apply("And then we left.", c) == " and then we left.")
    }

    @Test func terminalTypedSpace() {
        let (c, _) = resolve(buffer("prompt> Hello there. "), memory: "Hello there.")
        #expect(stage.apply("it was late.", c) == "It was late.")
    }

    @Test func terminalTrailingNewlinesIgnored() {
        #expect(resolve(buffer("x Hello there\n\n"), memory: "Hello there.").1 == "anchoredValue.end")
    }

    // Anchored value: editors (cursor mid-buffer, e.g. Emacs)

    @Test func editorCursorMidBuffer() {
        let text = ";; notes\nFirst line I said\n\nlater paragraph.\n"
        let (c, p) = resolve(buffer(text), memory: "line I said")
        #expect(p == "anchoredValue.interior")
        #expect(c.before?.hasSuffix("First line I said") == true)
        #expect(stage.apply("And more", c) == " and more")
    }

    @Test func editorDeletedCharacterMidBuffer() {
        let text = "Intro.\nWe agreed on it\nTail text.\n"
        let (c, p) = resolve(buffer(text), memory: "agreed on it.")
        #expect(p == "anchoredValue.interior")
        #expect(c.before?.hasSuffix("agreed on it") == true)
    }

    @Test func ambiguousAnchorFallsBackToMemory() {
        let text = "ok thanks\nok thanks\nmore"
        #expect(resolve(buffer(text), memory: "ok thanks").1 == "memory")
    }

    @Test func noAnchorFallsBackToMemory() {
        #expect(resolve(buffer("lots of new output scrolled in"), memory: "Hello there.").1 == "memory")
    }

    @Test func noMemoryMeansNoAnchor() {
        let (c, p) = resolve(buffer("abc"), memory: nil)
        #expect(p == "none")
        #expect(c.before == nil)
    }

    // Pluggability

    @Test func customProviderOrderIsHonoured() {
        struct Fixed: ContextProvider {
            let name = "fixed"
            func context(_ s: FieldSnapshot, memoryTail: String?) -> ProvidedContext? {
                ProvidedContext(before: "x", after: nil, source: .accessibility, provider: name)
            }
        }
        let (c, p) = InsertContext.resolve(snapshot: caretSnapshot("abc", ""), memoryTail: nil,
                                           pid: nil, bundleID: nil, engine: nil, secureInput: false,
                                           providers: [Fixed(), SelectionRangeProvider()])
        #expect(p == "fixed")
        #expect(c.before == "x")
    }
}
