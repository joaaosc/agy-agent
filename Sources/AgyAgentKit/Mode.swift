import Foundation

/// Modos de delegação suportados.
///
/// A distinção entre modos determina o prompt de sistema, o modelo padrão e
/// se o workspace é anexado à chamada. `inspect` pede somente leitura e audita
/// alterações, mas o backend ainda pode escrever dentro do sandbox.
public enum Mode: String, CaseIterable, Sendable, Codable {
    /// Pesquisa externa com busca na web; não depende do repositório.
    case research
    /// Leitura e diagnóstico do repositório corrente.
    case inspect
    /// Verificação pontual de um fato (API, versão, comportamento documentado).
    case verify
    /// Condensação de um texto ou diff já fornecido.
    case summarize

    /// Nome do arquivo de prompt em `prompts/`.
    public var promptFileName: String { "\(rawValue).md" }

    /// Modos que precisam do repositório corrente anexado via `--add-dir`.
    public var requiresWorkspace: Bool {
        switch self {
        case .inspect: true
        case .research, .verify, .summarize: false
        }
    }

    /// Modos que dependem de busca na web e, por isso, não podem ser
    /// memoizados indefinidamente: a resposta envelhece com o mundo.
    public var dependsOnWebSearch: Bool {
        switch self {
        case .research, .verify: true
        case .inspect, .summarize: false
        }
    }

    /// Modelo padrão. Pode ser sobrescrito por configuração ou por flag.
    public var defaultModel: String {
        switch self {
        case .research: "gemini-3.8-flash-high"
        case .inspect: "gemini-3.8-flash-medium"
        case .verify: "gemini-3.8-flash-medium"
        case .summarize: "gemini-3.8-flash-low"
        }
    }

    /// Tempo máximo padrão de uma chamada, em segundos.
    public var defaultTimeout: Duration {
        switch self {
        case .research: .seconds(300)
        case .inspect: .seconds(240)
        case .verify: .seconds(180)
        case .summarize: .seconds(120)
        }
    }

    /// Orçamento de resposta, em caracteres.
    ///
    /// Este é o número que importa para o objetivo da ferramenta: a resposta
    /// é a única parte que entra no contexto de quem chamou. Os tokens que o
    /// `agy` gasta do lado do Gemini não custam nada ao chamador; o texto que
    /// volta custa. Aproximadamente 4 caracteres por token, portanto os
    /// valores abaixo correspondem a algo entre 300 e 1000 tokens.
    public var responseBudget: Int {
        switch self {
        case .research: 3000
        case .inspect: 4000
        case .verify: 1200
        case .summarize: 2000
        }
    }

    /// Modos que rodam com `--sandbox`.
    ///
    /// Nenhuma flag conhecida impede escrita no workspace. A auditoria
    /// posterior detecta alterações, mas não as previne.
    /// O sandbox confina o alcance: bloqueia rede
    /// e acesso a arquivos fora do workspace. Por isso ele fica ligado
    /// justamente no modo que anexa o repositório, e desligado nos modos que
    /// precisam da web.
    public var usesSandbox: Bool { requiresWorkspace && !dependsOnWebSearch }
}
