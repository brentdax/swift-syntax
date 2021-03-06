//===------------------ RawSyntax.swift - Raw Syntax nodes ----------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

extension CodingUserInfoKey {
  /// Callback that will be called whenever a `RawSyntax` node is decoded
  /// Value must have signature `(RawSyntax) -> Void`
  static let rawSyntaxDecodedCallback =
    CodingUserInfoKey(rawValue: "SwiftSyntax.RawSyntax.DecodedCallback")!
  /// Function that shall be used to look up nodes that were omitted in the
  /// syntax tree transfer.
  /// Value must have signature `(SyntaxNodeId) -> RawSyntax`
  static let omittedNodeLookupFunction =
    CodingUserInfoKey(rawValue: "SwiftSyntax.RawSyntax.OmittedNodeLookup")!
}

extension ByteTreeUserInfoKey {
  /// Callback that will be called whenever a `RawSyntax` node is decoded
  /// Value must have signature `(RawSyntax) -> Void`
  static let rawSyntaxDecodedCallback =
    ByteTreeUserInfoKey(rawValue: "SwiftSyntax.RawSyntax.DecodedCallback")
  /// Function that shall be used to look up nodes that were omitted in the
  /// syntax tree transfer.
  /// Value must have signature `(SyntaxNodeId) -> RawSyntax`
  static let omittedNodeLookupFunction =
    ByteTreeUserInfoKey(rawValue: "SwiftSyntax.RawSyntax.OmittedNodeLookup")
}

/// Box a value type into a reference type
class Box<T> {
  let value: T

  init(_ value: T) {
    self.value = value
  }
}

/// A ID that uniquely identifies a syntax node and stays stable across multiple
/// incremental parses
public struct SyntaxNodeId: Hashable, Codable {
  private let rawValue: UInt

  // Start creating fresh node IDs for user generated nodes on in the upper
  // half of the UInt value range so that they don't easily collide with node
  // ids generated by the C++ side of libSyntax
  private static var highestUsedId: UInt = UInt.max / 2

  /// Generates a syntax node ID that has not been used yet
  fileprivate static func generateFreshId() -> SyntaxNodeId {
    return SyntaxNodeId(rawValue: highestUsedId + 1)
  }

  fileprivate init(rawValue: UInt) {
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    self.rawValue = try decoder.singleValueContainer().decode(UInt.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// The data that is specific to a tree or token node
fileprivate enum RawSyntaxData {
  /// A tree node with a kind and an array of children
  case node(kind: SyntaxKind, layout: [RawSyntax?])
  /// A token with a token kind, leading trivia, and trailing trivia
  case token(kind: TokenKind, leadingTrivia: Trivia, trailingTrivia: Trivia)
}

/// Represents the raw tree structure underlying the syntax tree. These nodes
/// have no notion of identity and only provide structure to the tree. They
/// are immutable and can be freely shared between syntax nodes.
final class RawSyntax {
  fileprivate let data: RawSyntaxData
  let presence: SourcePresence

  /// A ID that uniquely identifies this node and is persistent across
  /// incremental parses
  let id: SyntaxNodeId

  var _contentLength = AtomicCache<Box<SourceLength>>()

  /// The length of this node excluding its leading and trailing trivia
  var contentLength: SourceLength {
    return _contentLength.value({
      switch data {
      case .node(kind: _, layout: let layout):
        let firstElementIndex = layout.firstIndex(where: { $0 != nil })
        let lastElementIndex = layout.lastIndex(where: { $0 != nil })

        var contentLength = SourceLength.zero
        for (offset, element) in layout.enumerated() {
          guard let element = element else {
            continue
          }
          // Skip the node's leading trivia
          if offset != firstElementIndex {
            contentLength += element.leadingTriviaLength
          }
          contentLength += element.contentLength
          // Skip the node's trailing trivia
          if offset != lastElementIndex {
            contentLength += element.trailingTriviaLength
          }
        }
        return Box(contentLength)
      case .token(kind: let kind, leadingTrivia: _, trailingTrivia: _):
        return Box(SourceLength(of: kind.text))
      }
    }).value
  }

  init(kind: SyntaxKind, layout: [RawSyntax?], presence: SourcePresence,
       id: SyntaxNodeId? = nil) {
    self.data = .node(kind: kind, layout: layout)
    self.presence = presence
    self.id = id ?? SyntaxNodeId.generateFreshId()
  }

  init(kind: TokenKind, leadingTrivia: Trivia, trailingTrivia: Trivia,
       presence: SourcePresence, id: SyntaxNodeId? = nil) {
    self.data = .token(kind: kind, leadingTrivia: leadingTrivia,
                       trailingTrivia: trailingTrivia)
    self.presence = presence
    self.id = id ?? SyntaxNodeId.generateFreshId()
  }

  /// The syntax kind of this raw syntax.
  var kind: SyntaxKind {
    switch data {
    case .node(let kind, _): return kind
    case .token(_, _, _): return .token
    }
  }

  var tokenKind: TokenKind? {
    switch data {
    case .node(_, _): return nil
    case .token(let kind, _, _): return kind
    }
  }

  /// The layout of the children of this Raw syntax node.
  var layout: [RawSyntax?] {
    switch data {
    case .node(_, let layout): return layout
    case .token(_, _, _): return []
    }
  }

  /// Whether this node is present in the original source.
  var isPresent: Bool {
    return presence == .present
  }

  /// Whether this node is missing from the original source.
  var isMissing: Bool {
    return presence == .missing
  }

  /// Keys for serializing RawSyntax nodes.
  enum CodingKeys: String, CodingKey {
    // Shared keys
    case id, omitted

    // Keys for the `node` case
    case kind, layout, presence
    
    // Keys for the `token` case
    case tokenKind, leadingTrivia, trailingTrivia
  }

  public enum IncrementalDecodingError: Error {
    /// The JSON to decode is invalid because a node had the `omitted` flag set
    /// but included no id
    case omittedNodeHasNoId
    /// An omitted node was encountered but no node lookup function was
    /// in the decoder's `userInfo` for the `.omittedNodeLookupFunction` key
    /// or the lookup function had the wrong type
    case noLookupFunctionPassed
    /// A node with the given ID was omitted from the tranferred syntax tree
    /// but the lookup function was unable to look it up
    case nodeLookupFailed(SyntaxNodeId)
  }

  /// Creates a RawSyntax node that's marked missing in the source with the
  /// provided kind and layout.
  /// - Parameters:
  ///   - kind: The syntax kind underlying this node.
  ///   - layout: The children of this node.
  /// - Returns: A new RawSyntax `.node` with the provided kind and layout, with
  ///            `.missing` source presence.
  static func missing(_ kind: SyntaxKind) -> RawSyntax {
    return RawSyntax(kind: kind, layout: [], presence: .missing)
  }

  /// Creates a RawSyntax token that's marked missing in the source with the
  /// provided kind and no leading/trailing trivia.
  /// - Parameter kind: The token kind.
  /// - Returns: A new RawSyntax `.token` with the provided kind, no
  ///            leading/trailing trivia, and `.missing` source presence.
  static func missingToken(_ kind: TokenKind) -> RawSyntax {
    return RawSyntax(kind: kind, leadingTrivia: [], trailingTrivia: [], presence: .missing)
  }

  /// Returns a new RawSyntax node with the provided layout instead of the
  /// existing layout.
  /// - Note: This function does nothing with `.token` nodes --- the same token
  ///         is returned.
  /// - Parameter newLayout: The children of the new node you're creating.
  func replacingLayout(_ newLayout: [RawSyntax?]) -> RawSyntax {
    switch data {
    case let .node(kind, _):
      return RawSyntax(kind: kind, layout: newLayout, presence: presence)
    case .token(_, _, _): return self
    }
  }

  /// Creates a new RawSyntax with the provided child appended to its layout.
  /// - Parameter child: The child to append
  /// - Note: This function does nothing with `.token` nodes --- the same token
  ///         is returned.
  /// - Return: A new RawSyntax node with the provided child at the end.
  func appending(_ child: RawSyntax) -> RawSyntax {
    var newLayout = layout
    newLayout.append(child)
    return replacingLayout(newLayout)
  }

  /// Returns the child at the provided cursor in the layout.
  /// - Parameter index: The index of the child you're accessing.
  /// - Returns: The child at the provided index.
  subscript<CursorType: RawRepresentable>(_ index: CursorType) -> RawSyntax?
    where CursorType.RawValue == Int {
      return layout[index.rawValue]
  }

  /// Replaces the child at the provided index in this node with the provided
  /// child.
  /// - Parameters:
  ///   - index: The index of the child to replace.
  ///   - newChild: The new child that should occupy that index in the node.
  func replacingChild(_ index: Int,
                      with newChild: RawSyntax) -> RawSyntax {
    precondition(index < layout.count, "Cursor \(index) reached past layout")
    var newLayout = layout
    newLayout[index] = newChild
    return replacingLayout(newLayout)
  }
}

extension RawSyntax: TextOutputStreamable {
  /// Prints the RawSyntax node, and all of its children, to the provided
  /// stream. This implementation must be source-accurate.
  /// - Parameter stream: The stream on which to output this node.
  func write<Target>(to target: inout Target)
    where Target: TextOutputStream {
    switch data {
    case .node(_, let layout):
      for child in layout {
        guard let child = child else { continue }
        child.write(to: &target)
      }
    case let .token(kind, leadingTrivia, trailingTrivia):
      guard isPresent else { return }
      for piece in leadingTrivia {
        piece.write(to: &target)
      }
      target.write(kind.text)
      for piece in trailingTrivia {
        piece.write(to: &target)
      }
    }
  }
}

extension RawSyntax {
  var leadingTrivia: Trivia? {
    switch data {
    case .node(_, let layout):
      for child in layout {
        guard let child = child else { continue }
        guard let result = child.leadingTrivia else { break }
        return result
      }
      return nil
    case let .token(_, leadingTrivia, _):
      return leadingTrivia
    }
  }

  var trailingTrivia: Trivia? {
    switch data {
    case .node(_, let layout):
      for child in layout.reversed() {
        guard let child = child else { continue }
        guard let result = child.trailingTrivia else { break }
        return result
      }
      return nil
    case let .token(_, _, trailingTrivia):
      return trailingTrivia
    }
  }
}

extension RawSyntax {
  var leadingTriviaLength: SourceLength {
    return leadingTrivia?.sourceLength ?? .zero
  }

  var trailingTriviaLength: SourceLength {
    return trailingTrivia?.sourceLength ?? .zero
  }

  /// The length of this node including all of its trivia
  var totalLength: SourceLength {
    return leadingTriviaLength + contentLength + trailingTriviaLength
  }
}

// This is needed purely to have a self assignment initializer for
// RawSyntax.init(from:Decoder) so we can reuse omitted nodes, instead of
// copying them.
private protocol _RawSyntaxFactory {}
extension _RawSyntaxFactory {
  init(_instance: Self) {
    self = _instance
  }
}

extension RawSyntax: Codable, _RawSyntaxFactory {
  /// Creates a RawSyntax from the provided Foundation Decoder.
  convenience init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decodeIfPresent(SyntaxNodeId.self, forKey: .id)
    let omitted = try container.decodeIfPresent(Bool.self, forKey: .omitted) ?? false

    if omitted {
      guard let id = id else {
        throw IncrementalDecodingError.omittedNodeHasNoId
      }
      guard let lookupFunc = decoder.userInfo[.omittedNodeLookupFunction] as?
                               (SyntaxNodeId) -> RawSyntax? else {
        throw IncrementalDecodingError.noLookupFunctionPassed
      }
      guard let lookupNode = lookupFunc(id) else {
        throw IncrementalDecodingError.nodeLookupFailed(id)
      }
      self.init(_instance: lookupNode)
      return
    }

    let presence = try container.decode(SourcePresence.self, forKey: .presence)
    if let kind = try container.decodeIfPresent(SyntaxKind.self, forKey: .kind) {
      let layout = try container.decode([RawSyntax?].self, forKey: .layout)
      self.init(kind: kind, layout: layout, presence: presence, id: id)
    } else {
      let kind = try container.decode(TokenKind.self, forKey: .tokenKind)
      let leadingTrivia = try container.decode(Trivia.self, forKey: .leadingTrivia)
      let trailingTrivia = try container.decode(Trivia.self, forKey: .trailingTrivia)
      self.init(kind: kind, leadingTrivia: leadingTrivia,
                trailingTrivia: trailingTrivia, presence: presence, id: id)
    }
    if let callback = decoder.userInfo[.rawSyntaxDecodedCallback] as?
                        (RawSyntax) -> Void {
      callback(self)
    }
  }

  /// Encodes the RawSyntax to the provided Foundation Encoder.
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self.data {
    case let .node(kind, layout):
      try container.encode(id, forKey: .id)
      try container.encode(kind, forKey: .kind)
      try container.encode(layout, forKey: .layout)
    case let .token(kind, leadingTrivia, trailingTrivia):
      try container.encode(id, forKey: .id)
      try container.encode(kind, forKey: .tokenKind)
      try container.encode(leadingTrivia, forKey: .leadingTrivia)
      try container.encode(trailingTrivia, forKey: .trailingTrivia)
    }
    try container.encode(presence, forKey: .presence)
  }
}

extension RawSyntax: ByteTreeObjectDecodable {
  enum SyntaxType: UInt8, ByteTreeScalarDecodable {
    case token = 0
    case layout = 1
    case omitted = 2

    static func read(from pointer: UnsafeRawPointer, size: Int,
                     userInfo: UnsafePointer<[ByteTreeUserInfoKey: Any]>
    ) -> SyntaxType {
      let rawValue = UInt8.read(from: pointer, size: size, userInfo: userInfo)
      guard let type = SyntaxType(rawValue: rawValue) else {
        fatalError("Unknown RawSyntax node type \(rawValue)")
      }
      return type
    }
  }

  static func read(from reader: UnsafeMutablePointer<ByteTreeObjectReader>, 
                   numFields: Int, 
                   userInfo: UnsafePointer<[ByteTreeUserInfoKey: Any]>
  ) throws -> RawSyntax {
    let syntaxNode: RawSyntax
    let type = try reader.pointee.readField(SyntaxType.self, index: 0)
    let id = try reader.pointee.readField(SyntaxNodeId.self, index: 1)
    switch type {
    case .token:
      let presence = try reader.pointee.readField(SourcePresence.self, index: 2)
      let kind = try reader.pointee.readField(TokenKind.self, index: 3)
      let leadingTrivia = try reader.pointee.readField(Trivia.self, index: 4)
      let trailingTrivia = try reader.pointee.readField(Trivia.self, index: 5)
      syntaxNode = RawSyntax(kind: kind, leadingTrivia: leadingTrivia,
                             trailingTrivia: trailingTrivia,
                             presence: presence, id: id)
    case .layout:
      let presence = try reader.pointee.readField(SourcePresence.self, index: 2)
      let kind = try reader.pointee.readField(SyntaxKind.self, index: 3)
      let layout = try reader.pointee.readField([RawSyntax?].self, index: 4)
      syntaxNode = RawSyntax(kind: kind, layout: layout, presence: presence,
                             id: id)
    case .omitted:
      guard let lookupFunc = userInfo.pointee[.omittedNodeLookupFunction] as?
        (SyntaxNodeId) -> RawSyntax? else {
          throw IncrementalDecodingError.noLookupFunctionPassed
      }
      guard let lookupNode = lookupFunc(id) else {
        throw IncrementalDecodingError.nodeLookupFailed(id)
      }
      syntaxNode = lookupNode
    }
    if let callback = userInfo.pointee[.rawSyntaxDecodedCallback] as?
      (RawSyntax) -> Void {
      callback(syntaxNode)
    }
    return syntaxNode
  }
}

extension SyntaxNodeId: ByteTreeScalarDecodable {
  static func read(from pointer: UnsafeRawPointer, size: Int,
                   userInfo: UnsafePointer<[ByteTreeUserInfoKey: Any]>
  ) -> SyntaxNodeId {
    let rawValue = UInt32.read(from: pointer, size: size, userInfo: userInfo)
    return SyntaxNodeId(rawValue: UInt(rawValue))
  }
}

extension RawSyntax {
  func accept(_ visitor: RawSyntaxVisitor) {
    defer { visitor.moveUp() }
    guard isPresent else { return }
    switch data {
    case .node(let kind,let layout):
      let shouldVisit = visitor.shouldVisit(kind)
      var visitChildren = true
      if shouldVisit {
        // Visit this node realizes a syntax node.
        visitor.visitPre()
        visitChildren = visitor.visit() == .visitChildren
      }
      if visitChildren {
        for (offset, element) in layout.enumerated() {
          guard let element = element else { continue }
          // Teach the visitor to navigate to this child.
          visitor.addChildIdx(offset)
          element.accept(visitor)
        }
      }
      if shouldVisit {
        visitor.visitPost()
      }
    case .token(let kind, _, _):
      if visitor.shouldVisit(kind) {
        visitor.visitPre()
        _ = visitor.visit()
        visitor.visitPost()
      }
    }
  }
}
