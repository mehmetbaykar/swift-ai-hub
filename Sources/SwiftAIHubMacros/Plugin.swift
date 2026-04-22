// swift-ai-hub — Apache-2.0
// Compiler plugin entry point. Macros (@Tool, @Parameter, @Generable, @Guide)
// register here in docs/09 steps 4-5.

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SwiftAIHubMacrosPlugin: CompilerPlugin {
  let providingMacros: [any Macro.Type] = [
    GenerableMacro.self,
    GuideMacro.self,
  ]
}
