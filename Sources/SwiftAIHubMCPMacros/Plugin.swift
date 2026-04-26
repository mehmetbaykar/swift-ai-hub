import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SwiftAIHubMCPPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    MCPToolProviderMacro.self
  ]
}
