# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and releases use semantic versioning.

## [Unreleased]

## [0.1.0] - 2026-09-30

### Added

- Direct CLI modes for research, inspection, verification and summarization.
- Optional stdio MCP job server with bounded concurrency and cancellation.
- Optional loopback Responses provider with reversible installation.
- Five-hour usage reporting, local telemetry and configurable spend limits.
- Response budgets, cache, conversation resume and workspace change detection.
- External latency diagnostics with wall time, backend time, turns and tokens.

### Security

- Capability path and HTTP header validation for the loopback endpoint.
- Workspace confinement for MCP file attachments.
- Prompts delivered to child processes through stdin instead of process
  arguments.

### Fixed

- MCP role jobs honor their requested timeout and response budget.
