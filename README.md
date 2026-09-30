# agy-agent

`agy-agent` é uma CLI macOS e um servidor MCP que delega pesquisa, inspeção,
verificação e sumarização ao `agy`. A ferramenta limita a resposta que volta ao
chamador, mantém cache local, registra somente métricas operacionais e oferece
uma integração opcional com clientes compatíveis com MCP e Responses.

## Requisitos

- macOS 15 ou posterior;
- Swift 6.4 ou posterior para compilar;
- `agy` 1.2.x instalado, autenticado e disponível no `PATH`, em `AGY_BIN` ou
  configurado por `agy_path`;
- a CLI `codex` somente para os comandos opcionais `mcp-enable`, `mcp-disable`
  e para a instalação automática do provider local.

O projeto não possui dependências Swift externas.

## Instalação

```bash
git clone https://github.com/joaaosc/agy-agent.git
cd agy-agent
swift build -c release
"$(swift build -c release --show-bin-path)/agy-agent" install
```

Isso cria `~/.local/bin/agy-agent`, semeia os prompts e cria um modelo de
configuração. O alias genérico `usage` é opcional:

```bash
"$(swift build -c release --show-bin-path)/agy-agent" install --with-usage-alias
```

Se `~/.local/bin` ainda não estiver no `PATH`, acrescente-o à configuração do
shell. Para remover apenas os links e preservar configuração, bancos e prompts:

```bash
agy-agent install --uninstall
```

## Uso direto

```bash
agy-agent verify "A API X existe nesta versão?"
agy-agent research "qual é o estado atual do suporte a X?"
agy-agent inspect "por que este build falha?"
agy-agent summarize --file mudancas.diff "resuma as mudanças"
```

A pergunta também pode vir por stdin. O prompt é enviado ao processo filho por
stdin, sem aparecer na lista de argumentos do sistema:

```bash
printf '%s\n' 'verifique este comportamento' | agy-agent verify
```

Somente a resposta vai para stdout. Diagnóstico, proveniência, cache, custo e o
identificador de conversa vão para stderr. Use `--conversation ID` para retomar
uma conversa sem reenviar seu histórico. Opções disponíveis:

```text
--model M  --timeout S  --budget N  --file CAMINHO
--conversation ID  --refresh  --no-cache  --json  --quiet
```

O orçamento de retorno possui teto absoluto de 8.000 caracteres. Resposta vazia
é erro e não entra no cache. Anexos por arquivo são limitados a 20 MiB.

## MCP

O servidor stdio expõe uma ferramenta, `agy_job`, com as ações `spawn`,
`status`, `wait`, `result` e `cancel`. `spawn` devolve imediatamente um
identificador; `wait` aguarda até um segundo e pode ser repetido. Há no máximo
dois jobs simultâneos.

Registro automático no Codex:

```bash
agy-agent mcp-enable
agy-agent mcp-disable
```

Outros clientes MCP podem iniciar diretamente:

```text
~/.local/bin/agy-agent mcp-serve
```

Inicie o cliente dentro do projeto que será analisado. O servidor fixa esse
diretório como workspace dos jobs; se for iniciado no diretório home ou na raiz
do sistema, os papéis de inspeção falham de forma fechada.

Anexos recebidos pelo MCP precisam ser arquivos regulares dentro do diretório
em que o servidor foi iniciado. Caminhos externos e escapes por symlink são
recusados. O uso direto da CLI aceita um caminho explícito fornecido pelo próprio
usuário.

## Provider local opcional

```bash
agy-agent codex-enable
agy-agent codex-status
agy-agent codex-disable
```

`codex-enable` instala uma cópia gerenciada do executável, registra o MCP,
adiciona um provider Responses ao arquivo de configuração e inicia um
LaunchAgent. O endpoint escuta somente em `127.0.0.1`, usa um caminho aleatório
de 256 bits armazenado com permissão `0600`, valida `Host` e rejeita requisições
com `Origin`. `codex-disable` remove apenas artefatos identificados como
gerenciados e restaura uma instalação anterior quando houver backup.

Reinicie o cliente depois de ativar ou desativar a integração.

## Medição de uso

```bash
agy-agent usage
agy-agent report
agy-agent report --detalhado
agy-agent watch 15
agy-agent metrics
agy-agent metrics --erros
agy-agent metrics --latencia
```

`usage` mostra três linhas: janela do Claude, janela do Codex e consumo do
executor externo nas últimas cinco horas. Os percentuais dos clientes vêm de
snapshots encontrados nos transcritos locais quando disponíveis; a linha do
executor é calculada pela telemetria local e pelo teto configurado.

O relatório distingue:

- **medida**: caracteres devolvidos e reaproveitados pelo cache;
- **estimativa**: conversão local de quatro caracteres por token;
- **limite superior**: trabalho processado pelo executor, descontado o overhead
  observado;
- **alavancagem**: trabalho externo por token devolvido ao chamador.

Essas métricas não equivalem à fatura nem a uma cota oficial do provedor.

## Latência dos jobs externos

O runtime é agentivo: uma solicitação pode gerar vários turnos de raciocínio e
chamadas de ferramentas antes da resposta final. Por isso duas tarefas com o
mesmo modelo podem levar tempos muito diferentes. O transporte MCP é
assíncrono e não mantém uma chamada longa bloqueada, mas não reduz o trabalho
executado pelo backend.

`metrics --latencia` mostra, sem armazenar conteúdo, as últimas chamadas com:

- tempo de parede, incluindo inicialização e encerramento do processo;
- tempo informado pelo backend;
- número de turnos de conversa reportado pelo backend, que não representa a
  quantidade de chamadas de ferramenta;
- tokens processados e resultado.

Para limitar um job iniciado pelo MCP, forneça `timeout` entre 1 e 900 segundos.
O campo é encaminhado ao processo externo e também possui uma margem local de
encerramento. `budget` limita os caracteres devolvidos; ele não reduz, por si
só, o número de turnos. Tarefas menores, perguntas factuais e anexos específicos
tendem a evitar buscas amplas. O CLI externo não oferece atualmente um limite
documentado de turnos ou chamadas de ferramenta, portanto o timeout é o teto
efetivo para esse caso.

## Limites de gasto

Antes de iniciar uma chamada real, a ferramenta soma as últimas cinco horas de
telemetria. Os padrões são 40 chamadas e 2.000.000 de tokens externos. Ajuste
no `~/.config/agy-agent/config.toml`:

```toml
max_calls_per_window = 40
max_agy_tokens_per_window = 2_000_000
```

Chamadas servidas do cache não consomem esses limites.

## Modos

| Modo | Workspace | Web | Sandbox padrão | Orçamento |
|---|---:|---:|---:|---:|
| `research` | não | sim | não | 3.000 caracteres |
| `inspect` | sim | não | sim | 4.000 caracteres |
| `verify` | não | sim | não | 1.200 caracteres |
| `summarize` | não | não | não | 2.000 caracteres |

`inspect` anexa a raiz do repositório e executa o backend com `--sandbox`.
Esse sandbox restringe rede e acesso fora do workspace, mas não garante que o
backend deixe o workspace intacto. A ferramenta compara Git/arquivos antes e
depois e avisa sobre mudanças; ela não as desfaz. Prefira uma árvore limpa.

A resolução de workspace nunca anexa o diretório home inteiro nem a raiz do
sistema, mesmo que existam marcadores globais como `~/AGENTS.md`.

## Configuração e dados

Todas as chaves são opcionais. A precedência é flag, tabela do modo, tabela
geral e padrão embutido. Um exemplo completo está em
[`Docs/config.exemplo.toml`](Docs/config.exemplo.toml).

| Caminho | Conteúdo |
|---|---|
| `~/.config/agy-agent/` | `config.toml`, prompts e token local do provider |
| `~/Library/Application Support/agy-agent/` | conhecimento, telemetria e estado |
| `~/Library/Caches/agy-agent/` | cache descartável |

Prompts e respostas não são gravados na telemetria. O cache e o banco de
conhecimento armazenam respostas para oferecer repetição e promoção explícita;
trate esses arquivos como dados do usuário.

`AGY_AGENT_HOME=/tmp/agy-agent-sandbox` redireciona todas as raízes de runtime,
o que é útil em testes e diagnósticos.

## Diagnóstico e desenvolvimento

```bash
agy-agent doctor
agy-agent paths
agy-agent modes
agy-agent locate
agy-agent config
agy-agent plan inspect "por que o build falha?"
agy-agent stats

swift test
swift build -c release -Xswiftc -warnings-as-errors
```

`doctor` não chama modelos. Integrações opcionais desativadas aparecem como
`OPCIONAL`; artefatos parcialmente instalados aparecem como falha.

Falhas de segurança devem ser enviadas pelo canal privado de vulnerabilidades
do repositório, sem abrir uma issue pública com tokens, prompts ou caminhos do
usuário.

O código é distribuído sob a licença [MIT](LICENSE).
