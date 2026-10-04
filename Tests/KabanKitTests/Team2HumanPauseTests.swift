import XCTest
import KabanProtocol
@testable import KabanKit

final class Team2HumanPauseTests: XCTestCase {
    func testReviewPauseRestoresReviewAndQueuedPauseStaysQueued() throws {
        let result = PipelineValidator.validate(yaml: PipelineTemplate.defaultYAML.replacingOccurrences(of: "model:", with: "model: fake"))
        let pipeline = try XCTUnwrap(result.config)
        let stage = try XCTUnwrap(pipeline.stages.first { $0.kind == .human })
        let review = TaskMachineState(taskId: "t", stageId: stage.id, state: .waitingHuman(.review))
        let paused = TaskMachine.transition(review, .human(.pause), pipeline: pipeline)
        XCTAssertEqual(paused.state.state, .paused)
        XCTAssertEqual(paused.state.pausedState, .waitingHuman(.review))
        let encoded = try JSONEncoder().encode(paused.state)
        let reopened = try JSONDecoder().decode(TaskMachineState.self, from: encoded)
        XCTAssertEqual(TaskMachine.transition(reopened, .human(.resume), pipeline: pipeline).state.state, .waitingHuman(.review))
        let queued = TaskMachineState(taskId: "q", stageId: stage.id, state: .queued(nil))
        let preAdmission = TaskMachine.transition(queued, .human(.pause), pipeline: pipeline)
        XCTAssertEqual(TaskMachine.transition(preAdmission.state, .human(.resume), pipeline: pipeline).state.state, .queued(nil))
        // Legacy paused values have no trustworthy prior admission origin.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]); object.removeValue(forKey: "pausedState")
        let legacy = try JSONDecoder().decode(TaskMachineState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(TaskMachine.transition(legacy, .human(.resume), pipeline: pipeline).state.state, .queued(nil))
    }
}
