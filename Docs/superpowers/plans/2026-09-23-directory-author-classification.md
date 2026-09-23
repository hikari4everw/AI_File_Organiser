# 目标目录理解与作者归档 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 根据现有资料库的目录结构、作品样本和作者身份准确归档作品。

**Architecture:** 保留现有 SwiftUI、GRDB 和安全执行器，新增作品索引、目录画像和作者身份单元；分类管线消费它们的结果，计划只接受明确审核的来源和合法目标。

**Tech Stack:** Swift 6.2+、macOS 26、SwiftUI、Vision、Foundation Models、GRDB 7.6.1。

**Spec:** `Docs/superpowers/specs/2026-09-23-directory-author-classification-design.md`

## Global Constraints

- 资料库少于一千部作品；首次覆盖全部名称和结构，每部最多读取五个代表页。
- 文件分析在本机进行；联网仅由用户主动通过浏览器搜索作者或社团名称。
- 不覆盖、不删除用户文件、不跨卷；实际移动都经最终确认并可撤销。
- 旧计划来源限制保持收件箱直接子项；规则编辑与旧作者目录合并不属于本计划。

## Review Focus

- Unicode 组合字符和全半角括号：解析作者但不错误合并身份。Task 3 测试。
- 同社团不同作者：不能指向同一作者目录。Task 3 测试。
- 文件不可读或索引截断：显示覆盖不足，不计入强证据。Task 2 测试。
- 嵌套收件箱来源及库内所选作品：只允许审核清单上的作品移动。Task 5 测试。
- 修改人工目录用途后旧方案：不能继续执行。Task 5 测试。

---

### Task 1: 作品边界与目标目录角色

**Files:** Create `Sources/AIFileOrganizerCore/LibraryWorkIndexer.swift`; modify `Sources/AIFileOrganizerCore/DestinationIndexer.swift`; test `Tests/AIFileOrganizerCoreTests/LibraryWorkIndexerTests.swift`.

**Interfaces:** Produces `LibraryWorkIndexer.index(root: URL) throws -> LibraryWorkIndex` with classification folders, creator containers, complete works and uncertain nodes. Work internals have no destination IDs.

- [ ] **Step 1: Write failing tests:** use temporary `bunga/作者/作品/001.jpg` and `002.jpg`, and direct `bunga/作品/001.jpg`; assert category, creator, complete work, no image destinations; include hidden and symlink children.
- [ ] **Step 2: Verify RED:** `swift test --filter LibraryWorkIndexerTests`. Expected: missing indexer or wrong role assertion.
- [ ] **Step 3: Implement:** scan real directories, identify complete image works, keep uncertain role distinct and allow user correction, preserve paths for nested inbox scanning.
- [ ] **Step 4: Verify GREEN:** `swift test --filter LibraryWorkIndexerTests`. Expected: PASS.
- [ ] **Step 5: Commit:** `git add Sources/AIFileOrganizerCore/DestinationIndexer.swift Sources/AIFileOrganizerCore/LibraryWorkIndexer.swift Tests/AIFileOrganizerCoreTests/LibraryWorkIndexerTests.swift && git commit -m 'feat: index work boundaries'`.

### Task 2: 目录画像与增量内容分析

**Files:** Create `Sources/AIFileOrganizerCore/CatalogAnalysisService.swift`; modify `Sources/AIFileOrganizerCore/NativeContentExtractor.swift` and `Sources/AIFileOrganizerCore/AppDatabase.swift`; test `Tests/AIFileOrganizerCoreTests/CatalogAnalysisTests.swift`.

**Interfaces:** Consumes `LibraryWorkIndex`; produces `CatalogAnalysisResult` with per-category profile, sample references, coverage and revision.

- [ ] **Step 1: Write failing tests:** >60 works all contribute names; five dispersed pages maximum; unreadable content lowers coverage; cancelling and restarting reuses completed items; manual description survives refresh.
- [ ] **Step 2: Verify RED:** `swift test --filter CatalogAnalysisTests`. Expected: missing analysis service or failed new assertions.
- [ ] **Step 3: Implement:** full name and structure census, bounded representative OCR and optional installed visual model; cache by file identity, modification and analysis version; persist manual overrides separately.
- [ ] **Step 4: Verify GREEN:** `swift test --filter CatalogAnalysisTests`. Expected: PASS.
- [ ] **Step 5: Commit:** `git add Sources/AIFileOrganizerCore Tests/AIFileOrganizerCoreTests/CatalogAnalysisTests.swift && git commit -m 'feat: analyze destination catalog'`.

### Task 3: 作品名与作者身份

**Files:** Create `Sources/AIFileOrganizerCore/WorkNameParser.swift` and `Sources/AIFileOrganizerCore/CreatorCatalog.swift`; modify `Sources/AIFileOrganizerCore/AppDatabase.swift`; test `Tests/AIFileOrganizerCoreTests/CreatorCatalogTests.swift`.

**Interfaces:** Produces `WorkNameParser.parse(_ name: String) -> ParsedWorkName` and `CreatorCatalog.resolve(_ parsed: ParsedWorkName, workspaceID: UUID) throws -> CreatorResolution`.

- [ ] **Step 1: Write failing tests:** `[社团 (作者)] 标题 [中国翻訳] [DL版]`; Unicode variants; confirmed JP/EN aliases; same circle with two authors; ambiguous multiple authors; missing English name remains missing.
- [ ] **Step 2: Verify RED:** `swift test --filter CreatorCatalogTests`. Expected: missing parser/catalog or failed assertion.
- [ ] **Step 3: Implement:** preserve original name and structured tags; only explicit local pairing or user confirmation creates cross-language alias; save source URL and chosen existing directory.
- [ ] **Step 4: Verify GREEN:** `swift test --filter CreatorCatalogTests`. Expected: PASS.
- [ ] **Step 5: Commit:** `git add Sources/AIFileOrganizerCore Tests/AIFileOrganizerCoreTests/CreatorCatalogTests.swift && git commit -m 'feat: resolve creator identities'`.

### Task 4: 证据分类与作者归档提案

**Files:** Modify `Sources/AIFileOrganizerCore/ClassificationPipeline.swift`, `Sources/AIFileOrganizerCore/DeterministicClassifier.swift` and `Sources/AIFileOrganizerCore/Models.swift`; test `Tests/AIFileOrganizerCoreTests/ClassificationTests.swift`.

**Interfaces:** Consumes `CatalogAnalysisResult` and `CreatorResolution`; produces `ClassificationProposal` with top candidates, cited evidence, creator decision and catalog revision.

- [ ] **Step 1: Write failing tests:** generic PDF match must not preempt a better content match; definite author routes to existing folder; unknown author stays at category root; different authors sharing a circle do not merge.
- [ ] **Step 2: Verify RED:** `swift test --filter ClassificationTests`. Expected: new assertions fail.
- [ ] **Step 3: Implement:** existing explicit rules first, then structural name pattern, discriminative text and optional visual evidence; send only compact candidates to local model; separate definite and review decisions.
- [ ] **Step 4: Verify GREEN:** `swift test --filter ClassificationTests`. Expected: PASS.
- [ ] **Step 5: Commit:** `git add Sources/AIFileOrganizerCore/ClassificationPipeline.swift Sources/AIFileOrganizerCore/DeterministicClassifier.swift Sources/AIFileOrganizerCore/Models.swift Tests/AIFileOrganizerCoreTests/ClassificationTests.swift && git commit -m 'feat: rank destinations by library evidence'`.

### Task 5: 安全建目录与所选旧作归位

**Files:** Modify `Sources/AIFileOrganizerCore/PlanBuilder.swift`, `Sources/AIFileOrganizerCore/SafePlanExecutor.swift` and `Sources/AIFileOrganizerCore/Models.swift`; test `Tests/AIFileOrganizerCoreTests/ExecutorTests.swift` and `Tests/AIFileOrganizerCoreTests/PathSafetyTests.swift`.

**Interfaces:** Consumes reviewed proposals and exact selected source IDs; produces an immutable plan with source allowlist, catalog revision and parent-bound nested folder creation. Legacy plans decode to inbox-direct-child scope.

- [ ] **Step 1: Write failing tests:** create `bunga/作者` under known category; nested inbox work and explicitly selected library work allowed; unselected library work, parent-child double selection, symlinks, stale revision and old-plan library sources blocked; undo leaves old directories intact.
- [ ] **Step 2: Verify RED:** `swift test --filter ExecutorTests`. Expected: new scope/path tests fail.
- [ ] **Step 3: Implement:** bind new single-level name to existing category ID, save reviewed source paths and snapshots, check volume, ancestry, collision, parent existence and revision in preflight; only remove owned empty directories on undo.
- [ ] **Step 4: Verify GREEN:** `swift test --filter ExecutorTests` and `swift test --filter PathSafetyTests`. Expected: PASS.
- [ ] **Step 5: Commit:** `git add Sources/AIFileOrganizerCore/PlanBuilder.swift Sources/AIFileOrganizerCore/SafePlanExecutor.swift Sources/AIFileOrganizerCore/Models.swift Tests/AIFileOrganizerCoreTests/ExecutorTests.swift Tests/AIFileOrganizerCoreTests/PathSafetyTests.swift && git commit -m 'feat: safely route works into creator folders'`.

### Task 6: 工作台、真实验收与文档

**Files:** Modify `Sources/AIFileOrganizerApp/OrganizerView.swift`, `Sources/AIFileOrganizerApp/AppModel.swift`, `README.md`, `Docs/ARCHITECTURE.md`, `Docs/PRIVACY.md`; test `Tests/AIFileOrganizerCoreTests/AppModelTests.swift` and `UITests/AIFileOrganizerUITests.swift`.

**Interfaces:** Consumes Task 1–5 services, exposes analysis progress, manual catalog correction, author alias confirmation, browser search and selected existing-work review.

- [ ] **Step 1: Write failing tests:** manual profile change invalidates pending proposals, confirmed alias reuses selected target, unselected library work never enters plan; UI shows coverage and final action count.
- [ ] **Step 2: Verify RED:** `swift test --filter AppModelTests`. Expected: new assertions fail.
- [ ] **Step 3: Implement:** separate catalog/creator panels and state from organizer workbench; show evidence, pending reasons, resume and optional model download; keep one final confirmation.
- [ ] **Step 4: Verify GREEN:** `swift test --filter AppModelTests`, `swift test`, `swift run AIFileOrganizerChecks`; run Xcode UI suite when matching Xcode 26 toolchain is available. Expected: PASS.
- [ ] **Step 5: Acceptance:** hold out at least 50 annotated cases (30 definite doujinshi, 20 confusable/other). Among 30, top-choice category ≥29 and batch-ready ≥24; zero incorrectly routed default-ready cases across 50. Report both visual-model modes without tuning on held-out cases.
- [ ] **Step 6: Commit:** `git add Sources/AIFileOrganizerApp Tests/AIFileOrganizerCoreTests/AppModelTests.swift UITests/AIFileOrganizerUITests.swift README.md Docs/ARCHITECTURE.md Docs/PRIVACY.md && git commit -m 'feat: review learned folders and creators'`.
