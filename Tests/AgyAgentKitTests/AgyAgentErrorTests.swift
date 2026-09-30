import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Descrição dos erros")
struct AgyAgentErrorTests {
    @Test("agyFailed inclui o detalhe do agy, não só o status")
    func agyFailedIncludesDetail() {
        // Achado ao ligar a telemetria: a descrição descartava `output` e
        // toda mensagem de erro no terminal escondia a causa real (cota
        // excedida, autenticação expirada) atrás de "agy retornou status X".
        let error = AgyAgentError.agyFailed(status: "ERROR", output: "autenticação expirada")
        #expect("\(error)".contains("autenticação expirada"))
        #expect("\(error)".contains("ERROR"))
    }

    @Test("agyFailed sem saída não deixa dois-pontos soltos")
    func agyFailedWithEmptyOutput() {
        #expect("\(AgyAgentError.agyFailed(status: "exit 1", output: ""))" == "agy retornou status exit 1")
    }

    @Test("malformedEnvelope inclui o texto recebido")
    func malformedEnvelopeIncludesOutput() {
        let error = AgyAgentError.malformedEnvelope("erro: cota excedida")
        #expect("\(error)".contains("cota excedida"))
    }

    @Test("Texto muito longo é cortado, não descartado")
    func longOutputIsTruncatedNotDropped() {
        let long = String(repeating: "a", count: 2000)
        let text = "\(AgyAgentError.agyFailed(status: "x", output: long))"
        #expect(text.count < 700)
        #expect(text.hasSuffix("…"))
    }

    @Test("kindLabel cobre todos os casos sem cair no branch padrão")
    func kindLabelIsExhaustive() {
        // Uma amostra de um representante por caso; o switch em si já
        // garante exaustividade em tempo de compilação.
        let samples: [AgyAgentError] = [
            .agyNotFound("x"), .malformedEnvelope("x"), .agyFailed(status: "x", output: "x"),
            .timedOut(seconds: 1), .workspaceRequired(.inspect), .emptyQuestion,
            .missingPrompt(.verify, URL(filePath: "/x")), .storeFailed("x"),
            .invalidConfiguration("x"), .spendLimitReached("x"),
            .processLaunchFailed(executable: "x", reason: "x"),
        ]
        #expect(Set(samples.map(\.kindLabel)).count == samples.count)
    }
}
