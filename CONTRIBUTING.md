# Contributing

## Development environment

- macOS 15 or later
- Swift 6.4 or later
- an authenticated `agy` installation for live integration checks

Build and test with:

```bash
swift test
swift build -c release -Xswiftc -warnings-as-errors
```

Unit tests must not depend on the user's real configuration, credentials or
runtime databases. Use `TemporaryDirectory` or set `AGY_AGENT_HOME` for process
tests. Live backend checks should be explicit and should never run in the normal
test suite.

## Changes

Keep the MCP schema small and backward compatible. Preserve the separation
between stdout responses and stderr diagnostics. Do not add prompt or response
content to telemetry. Changes to installation or removal must preserve files
that are not marked as managed by this project.

Before submitting a change, inspect `git diff`, run the complete test suite and
verify a release build. Security changes should include a regression test when
the behavior can be tested without external credentials.
