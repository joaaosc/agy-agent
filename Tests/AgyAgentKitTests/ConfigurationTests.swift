import Testing
import Foundation
@testable import AgyAgentKit

@Suite("Leitor de subconjunto TOML")
struct TOMLTests {
    @Test("Pares simples e tabelas de um nível")
    func basics() throws {
        let tables = try TOML.parse("""
        agy_path = "/opt/agy"
        timeout_seconds = 120

        [mode.inspect]
        model = "gemini-3.1-pro-high"
        sandbox = false
        """)
        #expect(tables[""]?["agy_path"] == .string("/opt/agy"))
        #expect(tables[""]?["timeout_seconds"] == .integer(120))
        #expect(tables["mode.inspect"]?["model"] == .string("gemini-3.1-pro-high"))
        #expect(tables["mode.inspect"]?["sandbox"] == .boolean(false))
    }

    @Test("Comentários e linhas em branco são ignorados")
    func comments() throws {
        let tables = try TOML.parse("""
        # comentário

        model = "x"  # à direita
        """)
        #expect(tables[""]?["model"] == .string("x"))
    }

    @Test("Cerquilha dentro de string não vira comentário")
    func hashInsideString() throws {
        #expect(try TOML.parse("model = \"a#b\"")[""]?["model"] == .string("a#b"))
    }

    @Test("Inteiro com separador é aceito")
    func underscoreInteger() throws {
        #expect(try TOML.parse("max_cache_age_seconds = 86_400")[""]?["max_cache_age_seconds"] == .integer(86400))
    }

    @Test("Escapes básicos em string entre aspas duplas")
    func escapes() throws {
        #expect(try TOML.parse(#"a = "linha\nfim""#)[""]?["a"] == .string("linha\nfim"))
        // String literal com aspas simples não interpreta escapes.
        #expect(try TOML.parse("a = 'linha\\nfim'")[""]?["a"] == .string("linha\\nfim"))
    }

    @Test("Construções não suportadas falham com número de linha")
    func unsupportedConstructs() {
        // Aceitar em silêncio faria a configuração parecer aplicada sem estar.
        let cases = [
            "a = [1, 2]",
            "a = {b = 1}",
            "a = \"\"\"texto\"\"\"",
            "a = 1.5",
            "a.b = 1",
            "[[array]]",
            "sem_igual",
            "a =",
            "a = \"sem fim",
        ]
        for text in cases {
            #expect(throws: TOML.ParseError.self, "deveria recusar: \(text)") {
                try TOML.parse(text)
            }
        }
    }

    @Test("Chave duplicada na mesma tabela é recusada")
    func duplicateKey() {
        #expect(throws: TOML.ParseError.self) {
            try TOML.parse("a = 1\na = 2")
        }
    }

    @Test("O erro aponta a linha correta")
    func errorLine() {
        do {
            _ = try TOML.parse("a = 1\nb = 2\nc = [1]")
            Issue.record("deveria ter falhado")
        } catch let error as TOML.ParseError {
            #expect(error.line == 3)
        } catch {
            Issue.record("erro inesperado: \(error)")
        }
    }
}

@Suite("Configuração e precedência")
struct ConfigurationTests {
    @Test("Sem arquivo, todo modo usa os padrões")
    func defaults() {
        let configuration = Configuration.empty
        for mode in Mode.allCases {
            let settings = configuration.settings(for: mode)
            #expect(settings.model == mode.defaultModel)
            #expect(settings.timeout == mode.defaultTimeout)
            #expect(settings.responseBudget == mode.responseBudget)
            #expect(settings.sandboxed == mode.usesSandbox)
        }
    }

    @Test("Arquivo ausente não é erro")
    func missingFileIsNotAnError() throws {
        let url = URL(filePath: "/caminho/que/não/existe/config.toml", directoryHint: .notDirectory)
        #expect(try Configuration.load(from: url) == .empty)
    }

    @Test("Tabela geral sobrescreve o padrão de todos os modos")
    func generalOverride() throws {
        let configuration = try Configuration.parse("model = \"gemini-3.1-pro-low\"")
        for mode in Mode.allCases {
            #expect(configuration.settings(for: mode).model == "gemini-3.1-pro-low")
        }
    }

    @Test("Tabela de modo vence a geral")
    func modeOverridesGeneral() throws {
        let configuration = try Configuration.parse("""
        model = "geral"

        [mode.verify]
        model = "especifico"
        """)
        #expect(configuration.settings(for: .verify).model == "especifico")
        #expect(configuration.settings(for: .research).model == "geral")
    }

    @Test("Campos são resolvidos isoladamente")
    func fieldsResolveIndependently() throws {
        // Definir model no modo não pode arrastar junto o timeout da geral
        // nem descartar os outros padrões.
        let configuration = try Configuration.parse("""
        timeout_seconds = 30

        [mode.inspect]
        model = "x"
        """)
        let settings = configuration.settings(for: .inspect)
        #expect(settings.model == "x")
        #expect(settings.timeout == .seconds(30))
        #expect(settings.responseBudget == Mode.inspect.responseBudget)
        #expect(settings.sandboxed == Mode.inspect.usesSandbox)
    }

    @Test("Todos os campos configuráveis chegam ao resultado")
    func allFields() throws {
        let configuration = try Configuration.parse("""
        agy_path = "/opt/agy"

        [mode.research]
        model = "m"
        timeout_seconds = 45
        response_budget = 500
        max_cache_age_seconds = 60
        sandbox = true
        """)
        #expect(configuration.agyPath == "/opt/agy")
        let settings = configuration.settings(for: .research)
        #expect(settings.model == "m")
        #expect(settings.timeout == .seconds(45))
        #expect(settings.responseBudget == 500)
        #expect(settings.maxCacheAge == .seconds(60))
        #expect(settings.sandboxed)
    }

    @Test("Chave desconhecida é recusada em vez de ignorada")
    func unknownKey() {
        #expect(throws: AgyAgentError.self) {
            try Configuration.parse("modelo = \"x\"")
        }
    }

    @Test("Tabela desconhecida é recusada")
    func unknownTable() {
        #expect(throws: AgyAgentError.self) {
            try Configuration.parse("[modo.verify]\nmodel = \"x\"")
        }
    }

    @Test("Modo inexistente em [mode.*] é recusado")
    func unknownMode() {
        #expect(throws: AgyAgentError.self) {
            try Configuration.parse("[mode.explain]\nmodel = \"x\"")
        }
    }

    @Test("Valores com tipo ou faixa errada são recusados")
    func invalidValues() {
        for text in [
            "timeout_seconds = 0",
            "timeout_seconds = -5",
            "response_budget = 0",
            "model = \"\"",
            "sandbox = 1",
            "model = 3",
        ] {
            #expect(throws: AgyAgentError.self, "deveria recusar: \(text)") {
                try Configuration.parse(text)
            }
        }
    }

    @Test("Erro de sintaxe vira erro de configuração com a linha")
    func syntaxErrorIsReported() {
        do {
            _ = try Configuration.parse("model = [1]")
            Issue.record("deveria ter falhado")
        } catch let error as AgyAgentError {
            #expect("\(error)".contains("linha 1"))
        } catch {
            Issue.record("erro inesperado: \(error)")
        }
    }
}

@Suite("Biblioteca de prompts")
struct PromptLibraryTests {
    @Test("Os quatro prompts estão embarcados no bundle")
    func seedsArePresent() {
        for mode in Mode.allCases {
            let seed = PromptLibrary.bundledSeeds[mode]
            #expect(seed != nil, "faltou o prompt de \(mode.rawValue)")
            #expect(seed?.isEmpty == false)
        }
    }

    @Test("Arquivo local vence o prompt embutido")
    func localFileWins() throws {
        let directory = URL(filePath: "/config/prompts", directoryHint: .isDirectory)
        let library = PromptLibrary(directory: directory, readFile: { url in
            url.lastPathComponent == "verify.md" ? "prompt local" : nil
        })
        #expect(try library.prompt(for: .verify) == "prompt local")
        #expect(library.origin(for: .verify) == "/config/prompts/verify.md")
    }

    @Test("Sem arquivo local, usa o embutido em vez de falhar")
    func fallsBackToSeed() throws {
        let library = PromptLibrary(
            directory: URL(filePath: "/config/prompts", directoryHint: .isDirectory),
            readFile: { _ in nil }
        )
        #expect(try library.prompt(for: .inspect).contains("somente-leitura"))
        #expect(library.origin(for: .inspect) == "embutido")
    }

    @Test("Arquivo local vazio não sobrepõe o embutido")
    func emptyLocalFileIsIgnored() throws {
        let library = PromptLibrary(
            directory: URL(filePath: "/config/prompts", directoryHint: .isDirectory),
            readFile: { _ in "   \n  " }
        )
        #expect(try library.prompt(for: .verify) == PromptLibrary.bundledSeeds[.verify])
    }

    @Test("Sem arquivo e sem embutido, falha explicitamente")
    func missingEverything() {
        let library = PromptLibrary(
            directory: URL(filePath: "/config/prompts", directoryHint: .isDirectory),
            seeds: [:],
            readFile: { _ in nil }
        )
        #expect(throws: AgyAgentError.self) {
            try library.prompt(for: .verify)
        }
    }

    @Test("A semeadura escreve no disco sem sobrescrever o que já existe")
    func seedingDoesNotOverwrite() throws {
        let directory = try TemporaryDirectory()
        let prompts = directory.url.appending(path: "prompts")
        let library = PromptLibrary(directory: prompts)

        let written = try library.seedMissing()
        #expect(Set(written) == Set(Mode.allCases))

        let verifyURL = prompts.appending(path: "verify.md")
        try Data("editado pelo usuário".utf8).write(to: verifyURL)

        let again = try library.seedMissing()
        #expect(again.isEmpty)
        #expect(try String(contentsOf: verifyURL, encoding: .utf8) == "editado pelo usuário")
    }

    @Test("Editar o prompt muda a chave de cache só daquele modo")
    func promptDigestIsPerMode() {
        let neutral = URL(filePath: "/tmp", directoryHint: .isDirectory)
        func key(_ mode: Mode, prompt: String) -> String {
            DelegationRequest(mode: mode, question: "q", systemPrompt: prompt, neutralDirectory: neutral).query.cacheKey
        }
        #expect(key(.verify, prompt: "v1") != key(.verify, prompt: "v2"))
        #expect(key(.research, prompt: "r") == key(.research, prompt: "r"))
    }
}
