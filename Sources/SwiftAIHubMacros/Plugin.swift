// swift-ai-hub — Apache-2.0
// Compiler plugin entry point where the macros (@Tool, @Parameter,
// @Generable, @Guide) register.

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SwiftAIHubMacrosPlugin: CompilerPlugin {
  let providingMacros: [any Macro.Type] = [
    GenerableMacro.self,
    GuideMacro.self,
    ToolMacro.self,
    ParameterMacro.self,
  ]
}
