import Foundation

/// The default post-processing rules, embedded as a string constant rather than a
/// bundled resource file. This deliberately avoids SwiftPM's `Bundle.module`:
/// its generated accessor only finds the resource bundle at the build-time path
/// or `Bundle.main.bundleURL/<name>.bundle`, neither of which survives a
/// hand-assembled .app on another machine — the app would crash on launch looking
/// for a bundle that isn't there. Embedding sidesteps that entire failure mode.
enum DefaultRules {
    static let json = #"""
    {
        "_readme": [
            "Susurro post-processing rules.",
            "Your editable copy lives at: ~/Library/Application Support/Susurro/rules.json",
            "It is re-read on every dictation - edit, save, and just dictate again.",
            "",
            "options ......... on/off switches for the built-in pipeline stages",
            "punctuation ..... spoken trigger -> inserted symbol. Susurro handles word",
            "                  boundaries and strips stray commas/periods that whisper",
            "                  puts around trigger words. No regex needed.",
            "                  Add \"noSpaceBefore\": true to a rule if its symbol should",
            "                  hug the preceding word instead of getting a space before",
            "                  it, e.g. colon/semicolon below, or your own custom symbol.",
            "substitutions ... plain text fix-ups applied to the whole transcript,",
            "                  case-insensitive, whole-word. Good for jargon whisper",
            "                  mishears, e.g. 'launch DP list' -> 'launchd plist'.",
            "regexRules ...... power-user escape hatch. ICU regular expressions,",
            "                  case-insensitive, $1-style capture references.",
            "",
            "Every rule supports \"enabled\": false to switch it off without deleting it.",
            "Rules apply in the order they appear in each list."
        ],

        "options": {
            "pairQuotes": true,
            "autoCapitalize": true,
            "normalizeWhitespace": true
        },

        "punctuation": [
            { "say": "comma",             "insert": "," },
            { "say": "period",            "insert": "." },
            { "say": "full stop",         "insert": "." },
            { "say": "question mark",     "insert": "?" },
            { "say": "exclamation point", "insert": "!" },
            { "say": "colon",             "insert": ":", "noSpaceBefore": true },
            { "say": "semicolon",         "insert": ";", "noSpaceBefore": true },
            { "say": "new line",          "insert": "\n" },
            { "say": "backslash",         "insert": "\\" }
        ],

        "substitutions": [
            { "match": "launch DP list",  "replace": "launchd plist",  "enabled": false },
            { "match": "wisper CPP",      "replace": "whisper.cpp",    "enabled": false }
        ],

        "regexRules": [
            { "pattern": "\\bversion (\\d+) point (\\d+)\\b",  "template": "version $1.$2",  "enabled": false }
        ]
    }
    """#

    static var data: Data { Data(json.utf8) }

    static func decoded() -> PostProcessingRules? {
        try? JSONDecoder().decode(PostProcessingRules.self, from: data)
    }
}
