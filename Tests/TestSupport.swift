import Foundation
import RedraftCore

@MainActor
enum TestSupport {
  static func demoModel() throws -> WorkspaceViewModel {
    try WorkspaceViewModel(
      source: DemoWorkspaceContentSource(),
      reviewProvider: DemoReviewProvider(delay: .milliseconds(5)))
  }

  static func model(articles: [Article], examples: [RewriteExample] = []) throws
    -> WorkspaceViewModel
  {
    try WorkspaceViewModel(
      source: Source(
        seed: WorkspaceSeed(
          articles: articles.map { ArticleSeed(document: $0) }, examples: examples)),
      reviewProvider: NoReviewProvider())
  }

  struct Source: WorkspaceContentSource {
    let seed: WorkspaceSeed
    func load() -> WorkspaceSeed { seed }
  }
}

struct NoReviewProvider: ReviewProviding {
  func changes(for request: ReviewRequest) async throws -> [ReviewChange] { [] }
}
