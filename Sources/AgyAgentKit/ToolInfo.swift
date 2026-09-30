import Foundation

public enum ToolInfo {
    public static let version = "0.1.0"

    /// A ferramenta está ativa: instalável em `~/.local/bin` e com os quatro
    /// modos de delegação funcionando. Continua **não** registrada como
    /// servidor MCP até o usuário ativar explicitamente a integração.
    public static let isActive = true
}
