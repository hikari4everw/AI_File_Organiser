import Foundation

public struct DeterministicClassifier: Sendable {
  private static let categoryTokens: [String: Set<String>] = [
    "image": ["image", "images", "photo", "photos", "picture", "pictures", "图片", "照片", "截图"],
    "document": ["document", "documents", "doc", "docs", "文档", "资料", "文件"],
    "pdf": ["pdf", "papers", "paper", "论文", "阅读"],
    "audio": ["audio", "music", "sounds", "音乐", "音频"],
    "video": ["video", "videos", "movie", "movies", "视频", "影片"],
    "archive": ["archive", "archives", "zip", "compressed", "压缩包", "归档"],
    "installer": ["installer", "installers", "apps", "software", "安装包", "软件"],
    "spreadsheet": ["spreadsheet", "spreadsheets", "sheets", "表格", "报表"],
    "presentation": ["presentation", "presentations", "slides", "演示", "幻灯片"],
  ]

  public init() {}

  public func context(
    for item: ItemSnapshot,
    extracted: ExtractedContext = .init(),
    directorySummary: DirectorySummary? = nil
  ) -> ItemContext
  {
    let metadata = spotlightMetadata(for: item)
    return ItemContext(
      snapshot: item,
      normalizedKeywords: KeywordTokenizer.tokens(
        from: [
          item.name,
          metadata.title ?? "",
          metadata.authors.joined(separator: " "),
          metadata.contentType ?? "",
          String(extracted.text.prefix(500)),
          directorySummary?.representativeFiles.joined(separator: " ") ?? "",
          directorySummary?.extensionCounts.keys.sorted().joined(separator: " ") ?? "",
        ].joined(separator: " ")
      ),
      extracted: extracted,
      spotlightTitle: metadata.title,
      spotlightAuthors: metadata.authors,
      spotlightContentType: metadata.contentType,
      directorySummary: directorySummary
    )
  }

  public func rank(
    _ item: ItemContext, destinations: [DestinationProfile],
    catalog: CatalogAnalysisResult? = nil
  ) -> [RankedCandidate] {
    let category = category(for: item.snapshot)
    let itemTokens = Set(item.normalizedKeywords)
    let parsed = WorkNameParser().parse(item.snapshot.name)
    let profileByPath = Dictionary(uniqueKeysWithValues: (catalog?.profiles ?? []).map {
      ($0.relativePath, $0)
    })
    let extractedTokens = Set(KeywordTokenizer.tokens(from: item.extracted.text))
    let textTokensByPath = Dictionary(uniqueKeysWithValues: (catalog?.profiles ?? []).map { profile in
      (profile.relativePath, Set((catalog?.workAnalyses ?? [])
        .filter { $0.relativePath.hasPrefix(profile.relativePath + "/") }
        .flatMap { KeywordTokenizer.tokens(from: $0.extractedText) }))
    })
    let documentFrequency = textTokensByPath.values.reduce(into: [String: Int]()) { counts, tokens in
      for token in tokens { counts[token, default: 0] += 1 }
    }
    return destinations.compactMap { destination in
      let destinationTokens = Set(
        destination.keywords + KeywordTokenizer.tokens(from: destination.displayName))
      var score = 0.0
      var evidence: [Evidence] = []
      let overlap = itemTokens.intersection(destinationTokens)
      if !overlap.isEmpty {
        let value = min(0.65, Double(overlap.count) * 0.28)
        score += value
        evidence.append(
          Evidence(kind: "keyword", detail: overlap.sorted().joined(separator: ", "), weight: value)
        )
      }
      if let category, let expected = Self.categoryTokens[category],
        !destinationTokens.intersection(expected).isEmpty
      {
        score += 0.72
        evidence.append(Evidence(kind: "type", detail: "文件类型与目录用途一致", weight: 0.72))
      }
      if let type = item.snapshot.contentType,
        destination.sampleContentTypes.contains(where: { sameTypeFamily(type, $0) })
      {
        score += 0.35
        evidence.append(Evidence(kind: "profile", detail: "目标目录包含同类文件", weight: 0.35))
      }
      if let profile = profileByPath[destination.relativePath] {
        let examples = profile.workNames.map { WorkNameParser().parse($0) }
        let matchingShape = examples.filter {
          $0.circleName != nil && !$0.authorNames.isEmpty
        }
        if parsed.circleName != nil, !parsed.authorNames.isEmpty,
          matchingShape.count * 2 >= max(1, examples.count)
        {
          let value = matchingShape.count >= 2 ? 1.05 : 0.75
          score += value
          evidence.append(Evidence(kind: "name-pattern",
            detail: "作品名与目录内的社团、作者命名格式相符", weight: value))
          if examples.contains(where: { example in
            !Set(example.authorNames.map(CreatorCatalog.key))
              .isDisjoint(with: parsed.authorNames.map(CreatorCatalog.key))
          }) {
            score += 0.3
            evidence.append(Evidence(kind: "creator-example",
              detail: "目录内已有同一作者的作品", weight: 0.3))
          }
        }
        let rareOverlap = extractedTokens.intersection(textTokensByPath[profile.relativePath] ?? [])
          .filter { documentFrequency[$0] == 1 && $0.count >= 3 }
        if !rareOverlap.isEmpty {
          let value = min(0.5, Double(rareOverlap.count) * 0.16)
          score += value
          evidence.append(Evidence(kind: "content-text",
            detail: "正文与目录样本有特征词：" + rareOverlap.sorted().prefix(3).joined(separator: "、"),
            weight: value))
        }
        let purposeOverlap = itemTokens.intersection(KeywordTokenizer.tokens(from: profile.userPurpose))
        if !purposeOverlap.isEmpty {
          score += 0.4
          evidence.append(Evidence(kind: "purpose", detail: "符合人工标注的目录用途", weight: 0.4))
        }
      }
      guard score > 0 else { return nil }
      return RankedCandidate(
        destinationID: destination.id, score: score, evidence: evidence)
    }.sorted { lhs, rhs in
      lhs.score == rhs.score
        ? lhs.destinationID.uuidString < rhs.destinationID.uuidString : lhs.score > rhs.score
    }
  }

  public func proposal(sessionID: UUID, item: ItemContext, candidates: [RankedCandidate])
    -> ClassificationProposal?
  {
    guard let first = candidates.first else { return nil }
    let margin = first.score - (candidates.dropFirst().first?.score ?? 0)
    let ready = first.score >= 0.70 && margin >= 0.20 && !item.snapshot.isCloudPlaceholder
    return ClassificationProposal(
      sessionID: sessionID,
      itemID: item.id,
      action: .move,
      destinationID: first.destinationID,
      source: .deterministic,
      reviewDecision: ready ? .ready : .needsReview,
      reason: first.evidence.map(\.detail).joined(separator: "；"),
      evidence: first.evidence
    )
  }

  private func category(for item: ItemSnapshot) -> String? {
    let type = item.contentType ?? ""
    let ext = item.fileExtension
    if type.hasPrefix("public.image")
      || ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext)
    {
      return "image"
    }
    if type.hasPrefix("public.audio") || ["mp3", "m4a", "wav", "flac", "aac"].contains(ext) {
      return "audio"
    }
    if type.hasPrefix("public.movie") || ["mp4", "mov", "mkv", "m4v", "avi"].contains(ext) {
      return "video"
    }
    if type == "com.adobe.pdf" || ext == "pdf" { return "pdf" }
    if ["zip", "7z", "rar", "tar", "gz"].contains(ext) { return "archive" }
    if ["dmg", "pkg"].contains(ext) || item.kind == .applicationBundle { return "installer" }
    if ["xls", "xlsx", "csv", "numbers", "tsv"].contains(ext) { return "spreadsheet" }
    if ["ppt", "pptx", "key", "pps", "odp"].contains(ext) { return "presentation" }
    if type.hasPrefix("public.text") || ["txt", "md", "doc", "docx", "rtf"].contains(ext) {
      return "document"
    }
    return nil
  }

  private func sameTypeFamily(_ lhs: String, _ rhs: String) -> Bool {
    lhs == rhs || lhs.split(separator: ".").prefix(2) == rhs.split(separator: ".").prefix(2)
  }

  private func spotlightMetadata(for item: ItemSnapshot) -> (
    title: String?, authors: [String], contentType: String?
  ) {
    guard let metadata = NSMetadataItem(url: URL(fileURLWithPath: item.path)) else {
      return (nil, [], nil)
    }
    return (
      metadata.value(forAttribute: "kMDItemTitle") as? String,
      metadata.value(forAttribute: "kMDItemAuthors") as? [String] ?? [],
      metadata.value(forAttribute: "kMDItemContentType") as? String
    )
  }
}
