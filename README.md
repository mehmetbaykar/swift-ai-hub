# swift-ai-hub

Provider-agnostic Swift library merging AnyLanguageModel + Conduit + Swarm's `@Tool` macro. Writing `@Tool("...") struct X { @Generable struct Arguments { @Parameter("...") var q: String }; func execute(_ arguments: Arguments) async throws -> String }` gives you a struct usable over the MCP wire (via `swift-fast-mcp`) and inside an OpenAI/Anthropic tool-calling loop from the same declaration.

See [../SPEC.md](../SPEC.md) and [../docs/](../docs/) for the full spec. Implementation tracks the 18-step plan in [../docs/09-execution.md](../docs/09-execution.md).
