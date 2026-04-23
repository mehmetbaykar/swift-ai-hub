import struct Foundation.UUID

/// A unique identifier that is stable for the duration of a response, but not across responses.
///
/// The framework guarentees a `GenerationID` to be both present and stable when you
/// receive it from a `LanguageModelSession`. When you create an instance of
/// `GenerationID` there is no guarantee an identifier is present or stable.
///
/// ```swift
/// @Generable struct Person: Equatable {
///     var id: GenerationID
///     var name: String
/// }
///
/// struct PeopleView: View {
///     @State private var session = LanguageModelSession()
///     @State private var people = [Person.PartiallyGenerated]()
///
///     var body: some View {
///         // A person's name changes as the response is generated,
///         // and two people can have the same name, so it is not suitable
///         // for use as an id.
///         //
///         // `GenerationID` receives special treatment and is guaranteed
///         // to be both present and stable.
///         List {
///             ForEach(people) { person in
///                 Text("Name: \(person.name)")
///             }
///         }
///         .task {
///             for try! await people in stream.streamResponse(
///                 to: "Who were the first 3 presidents of the US?",
///                 generating: [Person].self
///             ) {
///                 withAnimation {
///                     self.people = people
///                 }
///             }
///         }
///     }
/// }
/// ```
public struct GenerationID: Sendable, Hashable, Codable {
  private let uuid: UUID
  private let rawString: String?

  /// Create a new, unique `GenerationID`.
  public init() {
    self.uuid = UUID()
    self.rawString = nil
  }

  /// Creates an id from a raw string produced by the model.
  private init(rawString: String) {
    self.uuid = UUID(uuidString: rawString) ?? UUID()
    self.rawString = rawString
  }
}

// MARK: - Generable conformance

extension GenerationID: Generable {
  /// The generation schema for `GenerationID`.
  ///
  /// Ids are string identifiers, so the schema is a plain string node. This ensures
  /// the macro's generic property-handling path renders `var id: GenerationID` inside
  /// a `@Generable` struct as a string — not as a nested object.
  public static var generationSchema: GenerationSchema {
    GenerationSchema.primitive(
      GenerationID.self,
      node: .string(
        GenerationSchema.StringNode(description: nil, pattern: nil, enumChoices: nil)
      )
    )
  }

  /// Creates a `GenerationID` from generated content. The content must be a string.
  public init(_ content: GeneratedContent) throws {
    guard case .string(let value) = content.kind else {
      throw GeneratedContentConversionError.typeMismatch
    }
    self.init(rawString: value)
  }

  /// An instance that represents the generated content.
  public var generatedContent: GeneratedContent {
    GeneratedContent(kind: .string(rawString ?? uuid.uuidString))
  }
}
