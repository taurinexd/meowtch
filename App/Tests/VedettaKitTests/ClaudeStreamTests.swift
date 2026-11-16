import Foundation
import Testing
@testable import VedettaKit

/// Lines captured from `claude` 2.1.325 in stream-json mode (2026-11-16).
struct ClaudeStreamTests {
    @Test func parsesTextDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}}"#
        #expect(ClaudeStream.parse(line: line) == .textDelta("ok"))
    }

    @Test func parsesResult() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1088,"result":"ok","total_cost_usd":0.00049058,"usage":{"output_tokens":4}}"#
        #expect(ClaudeStream.parse(line: line) == .result(ClaudeTurnResult(
            isError: false, text: "ok", costUSD: 0.00049058, durationMs: 1088, outputTokens: 4
        )))
    }

    @Test func rateLimitAndGarbageAreOther() {
        let rate = #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"seven_day":{"utilization":0.4}}}}"#
        #expect(ClaudeStream.parse(line: rate) == .other)
        #expect(ClaudeStream.parse(line: "not json") == .other)
        #expect(ClaudeStream.parse(line: "") == .other)
    }

    @Test func errorResultIsFlagged() {
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true}"#
        #expect(ClaudeStream.parse(line: line) == .result(ClaudeTurnResult(
            isError: true, text: "", costUSD: 0, durationMs: 0, outputTokens: 0
        )))
    }

    @Test func userLineRoundTrips() throws {
        let content = "Riga «uno»\n\"due\""
        let line = ClaudeStream.userLine(content)
        #expect(line.hasSuffix("\n"))
        #expect(!line.dropLast().contains("\n"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "user")
        let message = try #require(object["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        #expect(message["content"] as? String == content)
    }
}

struct QuickAnswerTests {
    @Test func visibleHidesPartialAndFullVerifyLine() {
        #expect(QuickAnswer.visible("Sì, entro giugno.\nVERIF") == "Sì, entro giugno.")
        #expect(QuickAnswer.visible("Sì, entro giugno.\nVERIFICA: cer") == "Sì, entro giugno.")
        #expect(QuickAnswer.visible("Sì, entro giugno.\nV") == "Sì, entro giugno.")
        #expect(QuickAnswer.visible("Sì, entro giugno.\nverifica: no") == "Sì, entro giugno.")
        #expect(QuickAnswer.visible("Va bene, ci sentiamo") == "Va bene, ci sentiamo")
    }

    @Test func visibleKeepsAnEarlierLineThatStartsWithV() {
        #expect(QuickAnswer.visible("Vi mando il link.\nPoi ne parliamo") == "Vi mando il link.\nPoi ne parliamo")
    }

    @Test func verifyReadsTheLastLine() {
        #expect(QuickAnswer.verify("Sì.\nVERIFICA: no") == nil)
        #expect(QuickAnswer.verify("Sì.") == nil)
        #expect(QuickAnswer.verify("Sì.\nVERIFICA: stato del checkout misto") == "stato del checkout misto")
    }
}

struct CallCopilotPromptTests {
    @Test func systemPromptCarriesContextAndTruncates() {
        let prompt = CallCopilotPrompt.system(webgas: "W", client: String(repeating: "x", count: 25_000))
        #expect(prompt.contains("VERIFICA"))
        #expect(prompt.contains("## Contesto Webgas"))
        #expect(prompt.contains("## Scheda cliente"))
        #expect(prompt.contains("[…troncato]"))
        #expect(!CallCopilotPrompt.system(webgas: nil, client: nil).contains("## Scheda cliente"))
    }

    @Test func personaForbidsCommitmentsInMatteosName() {
        // First runs suggested «ti scrivo oggi stesso», «entro venerdì».
        let prompt = CallCopilotPrompt.system(webgas: nil, client: nil)
        #expect(prompt.contains("mai impegni a nome di Matteo"))
        #expect(prompt.contains("ti faccio sapere"))
        // Seen live: «la parte di Matteo non è finita» from a client sheet
        // that names him in the third person.
        #expect(prompt.contains("Matteo, nel contesto, sei tu"))
    }

    @Test func userMessageLabelsSpeakers() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let lines = [
            CallLine(id: UUID(), speaker: .client, text: "Buongiorno.", isFinal: true, startedAt: t0, updatedAt: t0),
            CallLine(id: UUID(), speaker: .me, text: "Ciao!", isFinal: true, startedAt: t0, updatedAt: t0),
        ]
        let message = CallCopilotPrompt.userMessage(question: "Quando consegnate?", recent: lines)
        #expect(message.contains("Conversazione recente:\nCliente: Buongiorno.\nMatteo: Ciao!"))
        #expect(message.hasSuffix("Domanda del cliente: «Quando consegnate?»"))
    }

    @Test func userMessageWithoutRecentLinesIsJustTheQuestion() {
        #expect(CallCopilotPrompt.userMessage(question: "Q?", recent: []) == "Domanda del cliente: «Q?»")
    }
}

struct CallMetricsTests {
    @Test func metricsMedianAndP95() {
        var metrics = CallMetrics()
        [100, 200, 300, 400, 1000].forEach { metrics.recordDecision(endpointToDecisionMs: $0) }
        #expect(metrics.snapshot()["endpoint_to_decision_ms_median"] == 300)
        #expect(metrics.snapshot()["endpoint_to_decision_ms_p95"] == 1000)
        #expect(metrics.snapshot()["trigger_count"] == 5)
    }

    @Test func emptyMetricsOmitTimings() {
        var metrics = CallMetrics()
        #expect(metrics.snapshot()["endpoint_to_decision_ms_median"] == nil)
        metrics.recordOverride()
        metrics.recordFirstToken(decisionToFirstTokenMs: 800)
        #expect(metrics.snapshot()["manual_override_count"] == 1)
        #expect(metrics.snapshot()["decision_to_first_token_ms_median"] == 800)
    }
}
