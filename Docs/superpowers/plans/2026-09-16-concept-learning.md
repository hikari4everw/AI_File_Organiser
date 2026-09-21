# User-Taught File Concepts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users teach persistent, directory-independent file concepts from examples, recognize later files, and route them through reviewable organization and naming rules.

**Architecture:** Keep global concept definitions and explicit examples separate from workspace rules. A local feature extractor reads bounded representative pages; a recognizer compares versioned feature snapshots with positive and negative examples. The existing plan builder and executor remain the only route for file operations.

**Tech Stack:** Swift 6.2+, macOS 26+, SwiftUI, GRDB/SQLite, PDFKit, Vision, Core ML, Apple MobileCLIP image encoder. No cloud inference.

**Spec:** Approved conversation plan from 2026-09-16; this file records its execution decisions and test gate.

## Global Constraints

- User files and rendered pages stay local; do not persist page images or copy examples.
- Do not follow symbolic links or descend into app bundles. Keep directory analysis bounded to two levels and 200 entries; extract at most five image pages per item.
- Model downloads are pinned to `apple/coreml-mobileclip` revision `3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947`. S2's 71,397,632-byte weight file has SHA-256 `6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00`; B-LT's 172,707,392-byte weight file has SHA-256 `c12ec418eadf5d536f11e2e575b26c0d0bbc1270a7080d97f218a0a11595c289`. Only one validated feature version may be active in a concept snapshot.
- Concept evidence is explicit: confirmed positive or negative labels. A destination change alone does not teach a concept.
- Concepts are global to this Mac; destinations and rules are workspace-scoped. A concept has at most one direct parent; files may match multiple concepts.
- Low-confidence and conflicting results require review. The existing confirmed plan, preflight, no-overwrite execution, and undo remain authoritative.
- Preserve old rule decoding and existing move/naming learning samples; do not infer historical concepts from destinations.
- Validation uses disjoint whole-item teaching, calibration, and holdout groups; never split pages or chapters of one work between groups.

## Task 1: Baseline, corpus, and feasibility gate

**Files:** Create `Tests/AIFileOrganizerCoreTests/ConceptFeatureTests.swift`, `Sources/AIFileOrganizerCore/ConceptFeatureExtractor.swift`, `Sources/AIFileOrganizerChecks/ConceptBenchmark.swift` only as needed for the executable validation.

**Interfaces:** `ConceptFeatureExtractor.extract(item: ItemSnapshot) async throws -> ConceptFeatureSnapshot`; an injectable `ImageEmbeddingProvider` allows a deterministic test provider and the pinned Core ML implementation. Benchmark input is an explicit local manifest of whole-item paths and labels, not a copy of the corpus.

- [x] Inspect and record eligible whole-item counts and formats for R18 manga, ordinary manga, piano scores, and unknowns without displaying or modifying page content.
- [x] Write tests for bounded image selection, PDF page selection, cloud placeholders, unreadable content, cancellation, and model version tagging; verify the new tests fail for the missing capability.
- [x] Implement only the extractor and Core ML loading needed to encode the fixed corpus; run the focused tests to green.
- [x] Build teaching/calibration/holdout manifests with disjoint works and no path-derived label leakage. Freeze scoring thresholds on calibration; evaluate holdout without changing them.
- [x] Report overall and per-concept confident precision and coverage. Advance only when confident precision is at least 95% and coverage at least 50% on the agreed corpus; otherwise stop and review the failure before broadening implementation.
- [x] Run `swift test --filter ConceptFeatureTests` and `swift run AIFileOrganizerChecks` using writable build/module caches; commit the gate code and result summary, excluding the corpus and model weights.

## Task 2: Global concept data and explicit examples

**Files:** Create focused concept model/store/service files in `Sources/AIFileOrganizerCore`; extend `AppDatabase.swift`; add `ConceptStoreTests.swift`.

**Interfaces:** `FileConcept` has stable ID, name, description, aliases and optional parent ID. `ConceptExample` has item identity, concept ID, positive/negative label, versioned feature snapshot and timestamp. `ConceptStore` provides create/update/delete concept, add/retract example, list concepts/examples.

- [x] Write failing database tests for restart persistence, cross-workspace visibility, cycle rejection, duplicate example replacement, retraction, and deletion that disables referencing rules.
- [x] Add a new GRDB migration and minimal transactional CRUD. Reject invalid parent IDs and cycles; keep old data and rules decodable.
- [x] Test missing source files: the saved snapshot still participates in retrieval. Never copy page bytes into the database.
- [x] Run `swift test --filter ConceptStoreTests` plus database regression tests; commit the data layer.

## Task 3: Recognition and classification integration

**Files:** Create `ConceptRecognizer.swift`; extend `ClassificationPipeline.swift`, `Models.swift`, and focused classification tests.

**Interfaces:** `ConceptRecognitionResult` contains item ID, matched concept IDs, candidate IDs with evidence, status (`confirmed`, `confident`, `review`, `unknown`), and feature version. The recognizer accepts an `ItemContext`/snapshot plus global concepts/examples and returns no destination path.

- [x] Write failing tests for positive and negative examples, multiple concepts, ancestor propagation, unknown items, model unavailability, and low-confidence abstention.
- [x] Implement calibrated retrieval and evidence without treating raw similarity as a probability. Invalidate recognition cache when examples or feature version change.
- [x] Run recognition before destination decisions, including the existing fast deterministic branch. Preserve independent legacy rules; do not use unresolved concept matches as certain conditions.
- [x] Add integration tests proving an identified concept without a workspace route remains in place, while existing nonconcept behavior still runs for unknowns.
- [x] Run `swift test --filter ClassificationTests` and new recognition tests; commit the pipeline.

## Task 4: Concept-aware organization and naming rules

**Files:** Extend `RuleModels.swift`, `RuleEngine.swift`, `NamingRuleEngine.swift`, `RuleInterpretationEngine.swift`, `AppleRuleInterpreter.swift`, and focused rule tests.

**Interfaces:** `RuleCondition.conceptID: UUID?` is optional and defaults to nil when old JSON is decoded. Both rule engines receive concept recognition results and the concept hierarchy; they must not re-read files or invent paths.

- [x] Write failing tests for a concept-only route, combined concept and literal constraints, child-over-parent priority, unrelated conflicts, a missing/deleted concept, and old rule decoding.
- [x] Add a deterministic known-concept resolver before language-model interpretation. Ambiguous aliases and unresolved destinations produce incomplete editable drafts, never executable rules.
- [x] Apply concept conditions to both organization and naming rules; preserve existing filename validation and independent move/rename selection.
- [x] Run `swift test --filter RuleTests`, `RuleCreationTests`, and `NamingOperationTests`; commit the rule integration.

## Task 5: Teaching, correction, and review UI

**Files:** Add a concept management SwiftUI view; extend `AppModel.swift`, `OrganizerView.swift`, and `RulesView.swift`; add targeted app/UI tests.

**Interfaces:** The UI may select current items or explicitly selected external files. AppModel operations create/edit/delete concepts, teach positive/negative examples, confirm/correct a proposed concept, and refresh unexecuted proposals. Only existing plan/executor APIs move or rename files.

- [x] Write tests for teaching without a destination, correction without movement, external file selection, recognition display, and changed concepts invalidating a prepared plan.
- [x] Add concept management and batch teaching with optional parent and destination; the optional destination creates a workspace rule.
- [x] Show concept and destination separately in the inspector; provide confirm, reject, and replace label actions. Do not treat execution confirmation as concept confirmation.
- [x] Extend rule drafts to select a concept and target from approved IDs, displaying ambiguity before save.
- [x] Run unit and UI tests; commit the UI and AppModel integration.

## Task 6: Safety, compatibility, and final verification

**Files:** Update `README.md`, `docs/ARCHITECTURE.md`, `docs/PRIVACY.md` and the focused regression tests only where behavior changes.

- [x] Test symlinks, packages, unreadable and deleted examples, model corruption, feature-version mismatch, conflicting rules, cancellation, and multi-workspace isolation of routes.
- [x] Run `swift test`, `swift run AIFileOrganizerChecks`, and the Xcode test scheme with writable caches; inspect the complete results and diff.
- [x] Verify the real holdout again without changing its split or thresholds. Record precision, coverage, per-class confusion, and unsupported formats accurately.
- [x] Update user docs with model download, privacy, concept deletion, and low-confidence review behavior. Commit only code, tests, docs, and benchmark aggregate results; never commit corpus paths, content, or model weights.

## Execution notes

- The source fixture folder `测试文件` is untracked and 14 GB; use it read-only from the original checkout. A second user-authorized manga directory provides additional ordinary manga and R18 works; obtain its location from the user or task context without committing personal paths.
- `swift test` needs `--disable-sandbox`, a writable `XDG_CACHE_HOME`/`CLANG_MODULE_CACHE_PATH`, and the existing local GRDB checkout in this restricted environment.
- The source corpus currently has no artbook category. Do not claim four-category accuracy until the user supplies distinct artbook examples.

## Feasibility checkpoint (2026-09-16)

- The pinned MobileCLIP-S2 weight was downloaded to a temporary directory, matched the stated SHA-256, compiled with `coremlc`, and exposed a 256×256 image input and 512-dimensional output.
- The first image/PDF-only pilot left most ordinary manga unsupported because 16 folders chiefly contained EPUB. A temporary read-only EPUB page extractor increased usable ordinary manga to 26 works. The benchmark script and model are outside the repository and are not product code.
- The second pilot used 5 R18, 3 ordinary, and 5 score teaching works; separate calibration works; and 20 held-out works per class. Calibration selected a threshold without using holdout labels. The holdout had 55 confident predictions of 60 items: R18 17/19 correct, ordinary 13/16, and scores 20/20. Aggregate confident precision was 50/55 = 90.9%, below the required 95%; coverage was 55/60 = 91.7%.
- **Gate status: failed.** Do not mark Task 1 complete or implement Tasks 2–6 under this scoring configuration. Any new model or scoring approach needs a newly reserved holdout split; the current holdout has been examined and cannot serve as a fresh final validation set.

## Continuation checkpoint

- The user requested continuation. The stronger B-LT model was downloaded to a temporary directory, passed SHA-256 verification, and loaded in Core ML. On the same *already examined* 60-item split, it gave 42/43 correct confident predictions (97.7%) with 43/60 coverage (71.7%); R18 12/12, ordinary manga 10/11, and scores 20/20. This is a screening comparison, not an independent final acceptance result.
- Model-independent concept storage and explicit positive/negative correction can proceed while fresh ordinary-manga and artbook works are sought. Keep automatic concept confidence disabled until the agreed 95% / 50% gate is verified on a new holdout.

## Review-only implementation checkpoint

- Global concept CRUD, positive/negative examples, bounded PDF/EPUB/image features, pinned local B-LT model download, recognition, concept-aware organization/naming rules, deterministic natural-language concept anchors, and teaching/review UI are implemented on the isolated branch.
- A fixed-version, local hashed-text feature now supplies reviewable candidates for text-bearing files even when the optional image model is absent. It stores numerical vectors, not extracted text, and does not enable automatic confirmation.
- Automatic similarity confirmation remains disabled. New-file similarities are candidates requiring explicit review; only an explicit label (plus its ancestors) counts as confirmed for concept rules.
- A fresh read-only check using the previously frozen `0.35` similarity / `0.02` margin thresholds found 11/11 confident R18 results correct among 20, 20/20 confident scores correct among 20, and **10 false confident classifications among 20 distractor files** (11 readable). The proposed ordinary-manga nested directory provided no eligible new independent readable works after exclusion of previously sampled pages. This fails the agreed precision gate; these fresh items are now examined and cannot be reused as a final untouched holdout.
- The model threshold is therefore not present in product recognition. A new disjoint ordinary-manga and artbook corpus, plus new unknowns, is still required before enabling automatic confidence or claiming the 95% / 50% acceptance target.

## Completion audit (2026-09-21)

- Tasks 2–5 are complete for the review-only product path. Users can now replace an already confirmed concept directly; teaching immediately invalidates unexecuted plans and blocks preparation or execution until recognition refresh finishes.
- Changing a child concept invalidates naming suggestions derived from any ancestor that is no longer confirmed. Deleted concepts are rejected at both organization and naming rule-engine boundaries, including stale recognition-cache input.
- The Xcode project now gives the App and SwiftPM the same module name and uses the correct test host. UI tests use a temporary database and do not write test concepts into the user's application database.
- Final verification passed 175 Swift unit tests in 22 suites, 11 core safety checks, and the Xcode scheme with the same 175 unit tests plus 6 UI tests.
- Tasks 1 and 6 remain incomplete only at the independent corpus gate. No untouched, disjoint set currently covers ordinary manga, distinct artbooks, piano scores, and unknowns after the examined pilots. Automatic similarity confidence therefore remains disabled; candidates continue to require explicit review.

## Final corpus acceptance (2026-09-21)

- The user authorized read-only validation from the organized manga, `bunga` doujin, piano-score, and unrelated organized-file trees. Paths, manifests, model files, and file content were kept outside the repository.
- A 15-item teaching split used five whole items per known concept. The final holdout was frozen after calibration and contained 20 doujin, 20 ordinary-manga, 20 piano-score, and 20 unknown items. Piano scores included PDF and JPG/PNG work folders; one unknown item was unreadable, and all 60 known items were supported.
- Calibration fixed the MobileCLIP-BLT visual threshold at `0.75` with a `0.02` first-to-second margin. The independent holdout produced 32 correct confident predictions out of 33: **96.97% confident precision** and **55.0% known-item coverage**. Per class: doujin 5/5 confident correct (25% coverage), ordinary manga 8/8 (40%), piano score 19/20 (100%); 19 readable unknowns produced zero confident false positives.
- The 95% precision / 50% coverage gate passed. Product recognition now exposes a calibrated `confident` status only for the pinned visual model. It remains reviewable and does not automatically confirm a concept, fire a concept rule, choose a path, or bypass plan confirmation and preflight. Text similarity remains review-only.
- All six tasks are complete. Final verification passed 178 Swift tests in 22 suites, 11 core checks, the Xcode unit suite with the same 178 tests, and 6 UI tests.
