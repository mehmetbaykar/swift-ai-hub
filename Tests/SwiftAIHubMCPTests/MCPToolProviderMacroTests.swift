#if os(macOS)
  import MacroTesting
  import SwiftAIHubMCP
  import SwiftAIHubMCPMacros
  import Testing

  @Suite(
    .macros(
      [
        "MCPToolProvider": MCPToolProviderMacro.self
      ],
      record: .never
    )
  )
  struct MCPToolProviderMacroTests {
    @Test
    func `mcp provider macro expands streamable HTTP configuration`() {
      assertMacro {
        """
        @MCPToolProvider(
          name: "firecrawl",
          transport: .streamableHTTP(
            endpoint: "https://mcp.firecrawl.dev/v2/mcp",
            headers: .bearerToken(\\.apiKey)
          )
        )
        struct FirecrawlTools {
          let apiKey: String
        }
        """
      } expansion: {
        """
        struct FirecrawlTools {
          let apiKey: String

          public var name: String {
            "firecrawl"
          }

          public var toolNamePrefix: String? {
            nil
          }

          public func makeConfiguration() async throws -> SwiftAIHubMCP.MCPToolProvider.Configuration {
            SwiftAIHubMCP.MCPToolProvider.Configuration(
              name: "firecrawl",
              transport: .streamableHTTP(
                endpoint: Foundation.URL(string: "https://mcp.firecrawl.dev/v2/mcp")!,
                headers: {
                  ["Authorization": "Bearer \\(self.apiKey)"]
                },
                streaming: true
              ),
              toolNamePrefix: toolNamePrefix
            )
          }
        }

        extension FirecrawlTools: SwiftAIHubMCP.MCPToolProviderProtocol, Swift.Sendable {
        }
        """
      }
    }
  }
#endif
