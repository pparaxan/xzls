# AI usage

The XZLS project allows the usage of AI _when_ following [the policy](AI_POLICY.md). Contributions
that aren't following the AI Policy will be closed.

# Compile From Source

As part of the code editing workflow, consider the following commands:

- `zig build`: compile and install zls executable to `zig-out/bin/xzls`.
- `zig build check`: report compilation errors only (faster).
- `zig build check --watch -fincremental`: run compiler continously with incremental compilation.

# Testing

Use `zig build test` to run the XZLS test suite. This includes the following kinds of tests:

- Standalone unit tests in `./src`
- Code analysis tests in `./tests/analysis`
- LSP feature tests in `./tests/lsp_features`

Use `-Dtest-filter` to run a specific test or a subset of tests.

# Testing in Editor

To test the newly compiled ZLS built in your editor of choice, see the
[editor configuration guide](https://zigtools.org/zls/install/) and manually set the ZLS to the
binary in `./zig-out/bin/xzls`.

# Logging

See the [ZLS guide](https://zigtools.org/zls/guides/view-logs/) on how log messages can be
inspected. Editor logs are encouraged during development to inspect the output of
`std.debug.print` calls.

# Resources

- [LSP Specification](https://microsoft.github.io/language-server-protocol/specifications/specification-current)
- [Tracy Profiler](https://github.com/wolfpld/tracy) (See `-Denable-tracy` build option, a
[Zig port](https://github.com/allyourcodebase/tracy) is also available)
