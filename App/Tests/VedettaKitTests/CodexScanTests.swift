import Testing
import Foundation
@testable import VedettaKit

struct CodexScanTests {

    @Test func parsesRolloutMetaAndMessages() {
        let fixture = """
        {"type":"session_meta","payload":{"id":"abc-123","cwd":"/Users/x/Code/progetto","timestamp":"2026-07-08T15:56:19Z"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"quanto usage mi resta"}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ignorami"}]}}
        {"type":"event_msg","payload":{"type":"agent_message","message":"Te lo controllo subito."}}
        {"type":"event_msg","payload":{"type":"user_message","message":"grazie"}}
        """
        let rollout = CodexScan.parseRollout(Data(fixture.utf8))
        #expect(rollout.sessionId == "abc-123")
        #expect(rollout.cwd == "/Users/x/Code/progetto")
        #expect(rollout.firstUserMessage == "quanto usage mi resta")
        #expect(rollout.lastUserMessage == "grazie")
        #expect(rollout.lastAgentMessage == "Te lo controllo subito.")
    }

    @Test func parsesIndexNames() {
        let fixture = """
        {"id":"abc-123","thread_name":"Vecchio nome","updated_at":"2026-06-09T14:14:53Z"}
        {"id":"abc-123","thread_name":"Nome nuovo","updated_at":"2026-06-11T09:11:07Z"}
        {"id":"def-456","thread_name":"Altro thread","updated_at":"2026-06-11T09:11:07Z"}
        """
        let names = CodexScan.parseIndex(Data(fixture.utf8))
        #expect(names["abc-123"] == "Nome nuovo")
        #expect(names["def-456"] == "Altro thread")
    }

}
