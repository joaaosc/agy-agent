# Security policy

## Supported versions

Security fixes are applied to the latest release and to the default branch.

## Reporting a vulnerability

Use the repository's private vulnerability reporting channel. Include the
affected version, reproduction steps, impact and a minimal proof of concept.
Do not include access tokens, private prompts, response content or personal
filesystem paths.

Please do not open a public issue before a fix or mitigation is available.

## Security boundaries

The local Responses endpoint binds only to loopback and uses a random capability
path. The MCP server can start local processes and may send repository content
to the configured external backend. Review the backend's data policy before
using the tool with confidential source code.

The `inspect` sandbox limits network and filesystem reach, but it does not prove
that the attached workspace is immutable. Run it on a clean tree and review any
change reported by the workspace guard.
