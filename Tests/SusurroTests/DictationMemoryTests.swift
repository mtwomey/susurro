import Testing
@testable import SusurroCore

@Suite struct DictationMemoryTests {
    @Test func freshMemoryHasNoTail() {
        let memory = DictationMemory()
        #expect(memory.tailIfStillFocused(pid: 123) == nil)
    }

    @Test func recordedTailReturnedForSamePID() {
        var memory = DictationMemory()
        memory.recordTyped("Hello there.", intoPID: 123)
        #expect(memory.tailIfStillFocused(pid: 123) == ".")
    }

    @Test func recordedTailHiddenForDifferentPID() {
        var memory = DictationMemory()
        memory.recordTyped("Hello there.", intoPID: 123)
        #expect(memory.tailIfStillFocused(pid: 456) == nil)
    }

    @Test func singleCharacterTextReturnedInFull() {
        var memory = DictationMemory()
        memory.recordTyped("k", intoPID: 1)
        #expect(memory.tailIfStillFocused(pid: 1) == "k")
    }

    @Test func clearRemovesMemory() {
        var memory = DictationMemory()
        memory.recordTyped("Hello there.", intoPID: 123)
        memory.clear()
        #expect(memory.tailIfStillFocused(pid: 123) == nil)
    }

    @Test func recordingAgainOverwritesPreviousPID() {
        var memory = DictationMemory()
        memory.recordTyped("First one.", intoPID: 1)
        memory.recordTyped("Second one", intoPID: 2)
        #expect(memory.tailIfStillFocused(pid: 1) == nil)
        #expect(memory.tailIfStillFocused(pid: 2) == "e")
    }
}
