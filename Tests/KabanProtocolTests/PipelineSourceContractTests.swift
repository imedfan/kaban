import Foundation
import XCTest
import KabanProtocol

final class PipelineSourceContractTests: XCTestCase {
    func testExactSourceAndWrittenDraftRoundTripAndLegacyFlagRemainsAbsent() throws {
        let decoder = KabanCoding.makeDecoder(), encoder = KabanCoding.makeEncoder()
        let source = PipelineSourceContent(projectId: "p", path: "/tmp/repo/.kaban/pipeline.yaml", baseVersionHash: nil,
                                           baseSourceHash: "source", committedContent: nil, workingContent: "# 👋\r\n", worktreeSourceHash: "working")
        let result = CommandResult.pipelineSource(source), command = Command.getPipelineSource(projectId: "p")
        XCTAssertEqual(try decoder.decode(Command.self, from: encoder.encode(command)), command)
        XCTAssertEqual(try decoder.decode(CommandResult.self, from: encoder.encode(result)), result)
        var draft = PipelineDraft(projectId: "p", baseVersionHash: nil, content: "# exact\n", baseSourceHash: "source")
        XCTAssertNil(try decoder.decode(PipelineDraft.self, from: encoder.encode(draft)).requiresExactWorkingContent)
        draft.requiresExactWorkingContent = true
        XCTAssertEqual(try decoder.decode(PipelineDraft.self, from: encoder.encode(draft)), draft)
    }
    func testLegacyAndMalformedSourceFields() throws {
        let decoder = KabanCoding.makeDecoder(), encoder = KabanCoding.makeEncoder()
        var pipeline = Samples.pipeline
        XCTAssertNil(try decoder.decode(PipelineSummary.self, from: encoder.encode(pipeline)).sourceHash)
        pipeline.sourceHash = "sha256:source"
        pipeline.uncommittedIssues = [.init(path: "stages[1].agent.model", code: "model_missing", message: "Choose a model", severity: .error)]
        XCTAssertEqual(try decoder.decode(PipelineSummary.self, from: encoder.encode(pipeline)), pipeline)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(pipeline)) as? [String: Any])
        object["sourceHash"] = 7
        XCTAssertThrowsError(try decoder.decode(PipelineSummary.self, from: JSONSerialization.data(withJSONObject: object)))
        object["sourceHash"] = "source"; object["uncommittedIssues"] = "bad"
        XCTAssertThrowsError(try decoder.decode(PipelineSummary.self, from: JSONSerialization.data(withJSONObject: object)))
        let draft = PipelineDraft(projectId: "p", baseVersionHash: nil, content: "yaml", baseSourceHash: "source")
        XCTAssertEqual(try decoder.decode(PipelineDraft.self, from: encoder.encode(draft)), draft)
        var draftObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(draft)) as? [String: Any])
        draftObject["baseSourceHash"] = ["bad"]
        XCTAssertThrowsError(try decoder.decode(PipelineDraft.self, from: JSONSerialization.data(withJSONObject: draftObject)))
    }
    func testInvalidSourceCannotBeAuthorizedByNilVersionAlone() throws {
        let draft = PipelineDraft(projectId: "p", baseVersionHash: nil, content: "yaml")
        XCTAssertThrowsError(try draft.checkSourceBinding(currentSourceHash: "invalid-one"))
        try draft.checkSourceBinding(currentSourceHash: "empty", emptySourceHash: "empty")
        var bound = draft; bound.baseSourceHash = "invalid-one"
        try bound.checkSourceBinding(currentSourceHash: "invalid-one")
        XCTAssertThrowsError(try bound.checkSourceBinding(currentSourceHash: "invalid-two"))
    }
}
