import Foundation

// The bridge consumes BlockNote JSON, never HTML, Markdown, or ProseMirror's internal nodes.
indirect enum BlockNoteJSON: Equatable, Codable, Sendable {
  case object([String: Self])
  case array([Self])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let b = try? value.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? value.decode(Double.self), n.isFinite {
      self = .number(n)
    } else if let s = try? value.decode(String.self) {
      self = .string(s)
    } else if var list = try? decoder.unkeyedContainer() {
      var elements: [Self] = []
      while !list.isAtEnd { elements.append(try list.decode(Self.self)) }
      self = .array(elements)
    } else {
      self = .object(try value.decode([String: Self].self))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .object(let o): try value.encode(o)
    case .array(let a): try value.encode(a)
    case .string(let s): try value.encode(s)
    case .number(let n): try value.encode(n)
    case .bool(let b): try value.encode(b)
    case .null: try value.encodeNil()
    }
  }

  var object: [String: Self]? { if case .object(let v) = self { v } else { nil } }
  var array: [Self]? { if case .array(let v) = self { v } else { nil } }
  var string: String? { if case .string(let v) = self { v } else { nil } }
  var number: Double? { if case .number(let v) = self { v } else { nil } }
  var integer: Int? { number.flatMap(Int.init(exactly:)) }
}

typealias BlockNoteProps = [String: BlockNoteJSON]

enum BlockNoteType: String, Codable, Sendable {
  case paragraph, heading, bulletListItem, numberedListItem, checkListItem, quote, image, table

  var defaults: BlockNoteProps {
    var base: BlockNoteProps = ["textColor": .string("default")]
    if self == .table { return base }
    base["backgroundColor"] = .string("default")
    if self != .quote { base["textAlignment"] = .string("left") }
    switch self {
    case .heading: base["level"] = .number(1)
    case .checkListItem: base["checked"] = .bool(false)
    case .image:
      base.removeValue(forKey: "textColor")
      base["name"] = .string("")
      base["caption"] = .string("")
      base["url"] = .string("")
      base["showPreview"] = .bool(true)
    default: break
    }
    return base
  }

  func properties(_ raw: BlockNoteJSON?) throws -> BlockNoteProps {
    var optional: Set<String> = []
    if self == .numberedListItem { optional.insert("start") }
    if self == .image { optional.insert("previewWidth") }
    let props = try blockNoteProps(raw, allowed: Set(defaults.keys).union(optional))
    return defaults.merging(props) { _, supplied in supplied }
  }
}

/// Only accept the installed schema. Silently discarding a new prop/mark makes a save destructive.
func blockNoteProps(_ raw: BlockNoteJSON?, allowed: Set<String>) throws -> BlockNoteProps {
  guard let raw else { return [:] }
  guard let object = raw.object else { throw EditingError.invalidDocument }
  for (key, value) in object {
    guard allowed.contains(key) else { throw EditingError.invalidDocument }
    let valid: Bool
    switch key {
    case "textColor", "backgroundColor", "name", "url", "caption": valid = value.string != nil
    case "textAlignment": valid = ["left", "center", "right", "justify"].contains(value.string)
    case "bold", "italic", "underline", "strike", "code", "checked", "showPreview":
      if case .bool = value { valid = true } else { valid = false }
    case "level": valid = value.integer.map { (1...6).contains($0) } ?? false
    case "start": valid = value.integer != nil
    case "previewWidth": valid = value.number.map { $0.isFinite && $0 > 0 } ?? false
    case "colspan", "rowspan": valid = value == .number(1)  // This schema disables merged cells.
    default: valid = false
    }
    guard valid else { throw EditingError.invalidDocument }
  }
  return object
}
