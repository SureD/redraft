import Foundation
import RedraftCore

/// Composition-time data. The application chooses an empty, demo or restored source explicitly.
@MainActor
protocol WorkspaceContentSource {
  func load() -> WorkspaceSeed
}

struct WorkspaceSeed {
  var articles: [ArticleSeed] = []
  var examples: [RewriteExample] = []
}

struct ArticleSeed {
  var document: Article
  var versions: [ArticleVersion] = []
  var review: ReviewBatch? = nil
}

struct EmptyWorkspaceContentSource: WorkspaceContentSource {
  func load() -> WorkspaceSeed { WorkspaceSeed() }
}
