import Foundation

enum WorkspaceSection: String, CaseIterable { case articles, examples }
enum InspectorTab: String, CaseIterable { case marks, annotations, provenance }
enum ArticlePhase: String { case idle, running, ready }
enum ExampleFilter: String, CaseIterable {
  case all, accept, keep, rewrite
  var title: String {
    switch self {
    case .all: "全部取舍"
    case .accept: "采用"
    case .keep: "保留原文"
    case .rewrite: "自己改写"
    }
  }
}
enum WorkspaceSheet: String, Identifiable {
  case customMark, rewrite, shortcuts, statistics, about
  var id: String { rawValue }
}

/// Window-local state only. Documents, revisions and review tasks belong to ArticleSession.
struct WorkspaceState {
  var selectedArticleID: UUID? = nil
  var section: WorkspaceSection = .articles
  var sidebarVisible: Bool = false
  var proofreadingVisible: Bool = true
  var inspectorVisible: Bool = false
  var inspectorTab: InspectorTab = .marks
  var articleQuery: String = ""
  var exampleQuery: String = ""
  var exampleFilter: ExampleFilter = .all
  var selectedBlockID: UUID? = nil
  var selectedRange: NSRange = NSRange(location: 0, length: 0)
  var selectedChangeID: UUID? = nil
  var sheet: WorkspaceSheet? = nil
  var notice: String? = nil
  var dismissedAnnotationNotice: String? = nil
  var customInstruction: String = ""
  var rewriteText: String = ""
  var rewriteReason: String = ""
}
