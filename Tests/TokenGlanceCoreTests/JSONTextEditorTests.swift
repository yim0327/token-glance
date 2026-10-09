import Foundation
import Testing
@testable import TokenGlanceCore

struct JSONTextEditorTests {
    let tricky = """
    {
        "theme": "dark",
        "note": "a \\"statusLine\\" in a string { not a key }",
        "nested": { "statusLine": { "command": "inner" } },
        "statusLine": {
            "type": "command",
            "command": "node ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/omc-hud.mjs",
            "padding": 0
        },
        "emoji": "\u{D55C}\u{AE00} ✓"
    }

    """

    @Test func findsTopLevelMemberOnly() throws {
        let editor = try JSONTextEditor(tricky)
        let member = try #require(editor.topLevelMember("statusLine"))
        #expect(editor.text(member.value).hasPrefix("{\n        \"type\": \"command\""))
        let command = try #require(editor.member("command", inObjectAt: member.value))
        #expect(editor.text(command.value) == #""node ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/omc-hud.mjs""#)
        #expect(editor.topLevelMember("missing") == nil)
    }

    @Test func replacingAValueTouchesNothingElse() throws {
        var editor = try JSONTextEditor(tricky)
        let command = try #require(editor.member("command", inObjectAt: editor.topLevelMember("statusLine")!.value))
        editor.replace(command.value, with: #""/new/hook""#)
        let expected = tricky.replacingOccurrences(of: #""node ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/omc-hud.mjs""#, with: #""/new/hook""#)
        #expect(editor.string == expected)
    }

    @Test func insertThenRemoveRestoresOriginalBytes() throws {
        let original = "{\n    \"a\": 1,\n    \"b\": [1, 2]\n}\n"
        var editor = try JSONTextEditor(original)
        editor.insertTopLevelMember("statusLine", valueJSON: #"{"type": "command", "command": "x"}"#)
        #expect(editor.string == "{\n    \"a\": 1,\n    \"b\": [1, 2],\n    \"statusLine\": {\"type\": \"command\", \"command\": \"x\"}\n}\n")
        editor.removeTopLevelMember("statusLine")
        #expect(editor.string == original)
    }

    @Test func insertIntoEmptyAndCompactObjects() throws {
        var empty = try JSONTextEditor("{}")
        empty.insertTopLevelMember("k", valueJSON: "1")
        #expect(empty.string == "{\n  \"k\": 1\n}")

        var compact = try JSONTextEditor(#"{"a":1}"#)
        compact.insertTopLevelMember("k", valueJSON: "2")
        #expect(try JSONSerialization.jsonObject(with: Data(compact.string.utf8)) as? NSDictionary == ["a": 1, "k": 2])
    }

    @Test func removeFirstMiddleAndOnlyMember() throws {
        var first = try JSONTextEditor("{\n  \"x\": 1,\n  \"y\": 2\n}")
        first.removeTopLevelMember("x")
        #expect(first.string == "{\n  \"y\": 2\n}")

        var only = try JSONTextEditor("{\n  \"x\": {\"a\": [1, {\"b\": \"}\"}]}\n}\n")
        only.removeTopLevelMember("x")
        #expect(only.string == "{}\n")
    }

    @Test func rejectsNonObjectOrInvalidJSON() {
        #expect(throws: JSONTextEditor.Error.self) { try JSONTextEditor("[1, 2]") }
        #expect(throws: JSONTextEditor.Error.self) { try JSONTextEditor("{\"a\": }") }
        #expect(throws: JSONTextEditor.Error.self) { try JSONTextEditor("") }
    }

    @Test func encodesStringsWithoutEscapingSlashes() {
        #expect(JSONTextEditor.encode(string: #"'/a b/c' "q" \ "#) == #""'/a b/c' \"q\" \\ ""#)
    }
}
