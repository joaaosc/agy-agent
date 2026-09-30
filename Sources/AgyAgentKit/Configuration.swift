import Foundation

/// Configuração efetiva de um modo.
///
/// Precedência: flag de linha de comando > `config.toml` > padrão do modo.
/// Cada campo é resolvido isoladamente: definir `model` em `[mode.inspect]`
/// não deve arrastar junto o timeout padrão da tabela geral.
public struct ModeSettings: Sendable, Equatable {
    public var model: String
    public var timeout: Duration
    public var responseBudget: Int
    public var maxCacheAge: Duration
    public var sandboxed: Bool

    public init(model: String, timeout: Duration, responseBudget: Int, maxCacheAge: Duration, sandboxed: Bool) {
        self.model = model
        self.timeout = timeout
        self.responseBudget = responseBudget
        self.maxCacheAge = maxCacheAge
        self.sandboxed = sandboxed
    }

    public static func defaults(for mode: Mode) -> ModeSettings {
        ModeSettings(
            model: mode.defaultModel,
            timeout: mode.defaultTimeout,
            responseBudget: mode.responseBudget,
            maxCacheAge: Configuration.defaultMaxCacheAge,
            sandboxed: mode.usesSandbox
        )
    }
}

/// Configuração lida de `config.toml`.
///
/// Toda chave é opcional. O arquivo ausente é o caso normal, não um erro: a
/// ferramenta tem que funcionar sem configuração alguma.
public struct Configuration: Sendable, Equatable {
    public static let defaultMaxCacheAge: Duration = .seconds(86_400)

    /// Caminho explícito do `agy`, quando o usuário quiser fixar um.
    public var agyPath: String?
    /// Freio de gasto, comum a todos os modos.
    public var limits: SpendGuard.Limits = .default
    /// Valores que valem para todos os modos, salvo sobrescrita por modo.
    public var general: Overrides
    /// Sobrescritas por modo.
    public var byMode: [Mode: Overrides]

    public struct Overrides: Sendable, Equatable {
        public var model: String?
        public var timeoutSeconds: Int?
        public var responseBudget: Int?
        public var maxCacheAgeSeconds: Int?
        public var sandboxed: Bool?

        public init(
            model: String? = nil,
            timeoutSeconds: Int? = nil,
            responseBudget: Int? = nil,
            maxCacheAgeSeconds: Int? = nil,
            sandboxed: Bool? = nil
        ) {
            self.model = model
            self.timeoutSeconds = timeoutSeconds
            self.responseBudget = responseBudget
            self.maxCacheAgeSeconds = maxCacheAgeSeconds
            self.sandboxed = sandboxed
        }
    }

    public init(agyPath: String? = nil, general: Overrides = Overrides(), byMode: [Mode: Overrides] = [:]) {
        self.agyPath = agyPath
        self.general = general
        self.byMode = byMode
    }

    /// Configuração vazia — todos os padrões do modo.
    public static let empty = Configuration()

    // MARK: - Leitura

    /// Lê o arquivo, tratando ausência como configuração vazia.
    public static func load(from url: URL) throws -> Configuration {
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else {
            return .empty
        }
        return try parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ text: String) throws -> Configuration {
        let tables: [String: [String: TOML.Value]]
        do {
            tables = try TOML.parse(text)
        } catch let error as TOML.ParseError {
            throw AgyAgentError.invalidConfiguration(error.description)
        }

        var configuration = Configuration()
        let root = tables[""] ?? [:]
        configuration.agyPath = root["agy_path"]?.stringValue
        if let calls = try positive(root["max_calls_per_window"], key: "max_calls_per_window", table: "raiz") {
            configuration.limits.maxCalls = calls
        }
        if let tokens = try positive(root["max_agy_tokens_per_window"], key: "max_agy_tokens_per_window", table: "raiz") {
            configuration.limits.maxAgyTokens = tokens
        }
        configuration.general = try overrides(
            from: root,
            table: "raiz",
            ignoring: ["agy_path", "max_calls_per_window", "max_agy_tokens_per_window"]
        )

        for (name, values) in tables where name.hasPrefix("mode.") {
            let raw = String(name.dropFirst("mode.".count))
            guard let mode = Mode(rawValue: raw) else {
                throw AgyAgentError.invalidConfiguration("tabela `[\(name)]`: modo desconhecido `\(raw)`")
            }
            configuration.byMode[mode] = try overrides(from: values, table: name, ignoring: [])
        }

        // Uma tabela com nome errado seria ignorada em silêncio e o usuário
        // acharia que configurou algo. Melhor recusar.
        for name in tables.keys where !name.isEmpty && !name.hasPrefix("mode.") {
            throw AgyAgentError.invalidConfiguration("tabela `[\(name)]` não é reconhecida; use `[mode.<modo>]`")
        }
        return configuration
    }

    private static func overrides(
        from values: [String: TOML.Value],
        table: String,
        ignoring: Set<String>
    ) throws -> Overrides {
        var overrides = Overrides()
        let known: Set<String> = ["model", "timeout_seconds", "response_budget", "max_cache_age_seconds", "sandbox"]

        for key in values.keys where !known.contains(key) && !ignoring.contains(key) {
            throw AgyAgentError.invalidConfiguration("chave `\(key)` em `[\(table)]` não é reconhecida")
        }

        overrides.model = try string(values["model"], key: "model", table: table)
        overrides.timeoutSeconds = try positive(values["timeout_seconds"], key: "timeout_seconds", table: table)
        overrides.responseBudget = try positive(values["response_budget"], key: "response_budget", table: table)
        overrides.maxCacheAgeSeconds = try positive(values["max_cache_age_seconds"], key: "max_cache_age_seconds", table: table)
        if let value = values["sandbox"] {
            guard let flag = value.boolValue else {
                throw AgyAgentError.invalidConfiguration("`sandbox` em `[\(table)]` deve ser true ou false")
            }
            overrides.sandboxed = flag
        }
        return overrides
    }

    private static func string(_ value: TOML.Value?, key: String, table: String) throws -> String? {
        guard let value else { return nil }
        guard let text = value.stringValue, !text.isEmpty else {
            throw AgyAgentError.invalidConfiguration("`\(key)` em `[\(table)]` deve ser uma string não vazia")
        }
        return text
    }

    private static func positive(_ value: TOML.Value?, key: String, table: String) throws -> Int? {
        guard let value else { return nil }
        guard let number = value.intValue, number > 0 else {
            throw AgyAgentError.invalidConfiguration("`\(key)` em `[\(table)]` deve ser um inteiro positivo")
        }
        return number
    }

    // MARK: - Resolução

    /// Valores efetivos de um modo, aplicando a precedência.
    public func settings(for mode: Mode) -> ModeSettings {
        var settings = ModeSettings.defaults(for: mode)
        for layer in [general, byMode[mode] ?? Overrides()] {
            if let model = layer.model { settings.model = model }
            if let seconds = layer.timeoutSeconds { settings.timeout = .seconds(seconds) }
            if let budget = layer.responseBudget { settings.responseBudget = budget }
            if let seconds = layer.maxCacheAgeSeconds { settings.maxCacheAge = .seconds(seconds) }
            if let sandboxed = layer.sandboxed { settings.sandboxed = sandboxed }
        }
        return settings
    }
}
