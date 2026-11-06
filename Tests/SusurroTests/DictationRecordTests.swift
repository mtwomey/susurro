import Foundation
import Testing
@testable import SusurroCore

/// R7 (BEA-683, F14): the per-dictation log record.
@Suite struct DictationRecordTests {
    @Test func formatsAllFieldsInOrder() {
        let r = DictationRecord(
            trigger: .pushToTalk, engine: .whisper,
            timings: StageTimings(axRead: .milliseconds(12), transcribe: .milliseconds(340),
                                  joinTranscribe: nil, insert: .milliseconds(4)),
            source: .accessibility, provider: "ax", app: "com.apple.TextEdit",
            ax: "role=AXTextArea valueLen=23 caret=22", sameApp: true,
            cross: " xjoin=continue gap=1.2", outcome: .inserted)
        #expect(r.line == "trigger=ptt engine=whisper outcome=inserted source=accessibility provider=ax "
            + "app=com.apple.TextEdit ax=role=AXTextArea valueLen=23 caret=22 sameApp=true "
            + "xjoin=continue gap=1.2 ms_ax=12 ms_transcribe=340 ms_join=- ms_insert=4")
    }

    @Test func unknownFieldsRenderAsDash() {
        let r = DictationRecord(trigger: .handsFree, engine: .parakeet, transcriptionFailed: true,
                                outcome: .dropped)
        #expect(r.line == "trigger=handsfree engine=parakeet outcome=dropped source=- provider=- app=- "
            + "ax=- sameApp=- transcribeFailed=true ms_ax=- ms_transcribe=- ms_join=- ms_insert=-")
    }

    @Test func emptyCrossLogAddsNothing() {
        let r = DictationRecord(trigger: .devFeed, engine: .whisper, cross: "", outcome: .empty)
        #expect(!r.line.contains("  "))
        #expect(r.line.hasPrefix("trigger=devfeed "))
    }

    /// The record is built from what the insert path has in hand (field
    /// snapshot, resolved context, provider). None of the field's text — or
    /// the transcript — may reach the line.
    @Test func noFieldOrTranscriptTextReachesTheRecord() {
        let secret = "Dear Dr Quokka my password is hunter2"
        let snapshot = FieldSnapshot(value: secret, selection: NSRange(location: 20, length: 0),
                                     markerBefore: "hunter2", role: "AXTextArea",
                                     appBefore: secret, appBridge: "emacs")
        let (context, provider) = InsertContext.resolve(
            snapshot: snapshot, memory: nil, pid: 42, bundleID: "com.apple.TextEdit",
            engine: .whisper, secureInput: false)
        #expect(context.before != nil)  // the context really carried field text
        let r = DictationRecord(trigger: .pushToTalk, engine: .whisper, source: context.source,
                                provider: provider, app: "com.apple.TextEdit", ax: snapshot.detail,
                                sameApp: true, outcome: .inserted)
        for word in ["Dear", "Quokka", "password", "hunter2"] {
            #expect(!r.line.contains(word), "record leaked field text: \(r.line)")
        }
    }

    /// Guard against someone adding a text-carrying property later: the
    /// record's stored properties are exactly these.
    @Test func recordHasNoTextProperties() {
        let r = DictationRecord(trigger: .pushToTalk, engine: .whisper, outcome: .empty)
        let names = Mirror(reflecting: r).children.compactMap(\.label)
        #expect(names == ["trigger", "engine", "timings", "source", "provider", "app", "ax",
                          "sameApp", "cross", "transcriptionFailed", "outcome"])
    }

    @Test func subsystemFallsBackToBundleID() {
        // swift test runs outside the app bundle; the app itself uses its
        // CFBundleIdentifier, which is the same string.
        #expect(Log.subsystem.hasPrefix("com."))
    }
}
