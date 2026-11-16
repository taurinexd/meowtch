import Foundation

/// What the quick lane is told: the persona once per call (system prompt),
/// then one message per question.
public enum CallCopilotPrompt {
    /// Characters kept per context file.
    public static let contextLimit = 20_000

    public static func system(webgas: String?, client: String?) -> String {
        var parts = [persona]
        if let webgas, !webgas.isEmpty {
            parts.append("## Contesto Webgas\n\n" + truncated(webgas))
        }
        if let client, !client.isEmpty {
            parts.append("## Scheda cliente\n\n" + truncated(client))
        }
        return parts.joined(separator: "\n\n")
    }

    public static func userMessage(question: String, recent: [CallLine]) -> String {
        let ask = "Domanda del cliente: «\(question)»"
        guard !recent.isEmpty else { return ask }
        let lines = recent.map { "\($0.speaker == .client ? "Cliente" : "Matteo"): \($0.text)" }
        return "Conversazione recente:\n" + lines.joined(separator: "\n") + "\n\n" + ask
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > contextLimit else { return text }
        return String(text.prefix(contextLimit)) + "\n[…troncato]"
    }

    private static let persona = """
    Sei il copilota di Matteo, sviluppatore di Webgas, durante una call con un cliente. \
    Ti arriva la domanda appena fatta dal cliente e le ultime battute della conversazione.

    Rispondi con ciò che Matteo può dire ad alta voce, adesso:
    - italiano parlato, prima persona di Matteo, tono cordiale e diretto;
    - al massimo 2 righe, oppure 3 punti brevi;
    - niente premesse, niente «Puoi dire», niente virgolette: solo la frase;
    - mai inventare numeri, date, prezzi o stato dei lavori che non sono nel contesto: \
    in quel caso la frase è «lo verifico e ti faccio sapere», senza dire quando;
    - mai impegni a nome di Matteo: niente scadenze, orari o promesse di invio \
    («oggi stesso», «entro venerdì», «ti mando la cifra») che lui non ha già detto nella call;
    - non dire «sì» a una richiesta che il contesto non conferma.

    L'ultima riga è sempre di controllo e non viene mostrata: \
    `VERIFICA: no` se la risposta non dipende da fatti da controllare, altrimenti \
    `VERIFICA: <cosa cercare nel codice o nei documenti>`.
    """
}
