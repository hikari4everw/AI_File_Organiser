# AI File Organizer V2.1 Design

## Goal

The user selects a source folder and a separate same-volume library, sees an incremental organization draft grouped by destination, confirms an immutable plan, executes it safely, and can undo completed moves after restart. Classification remains local and combines explicit rules, bounded content extraction, library profiles, and Apple Foundation Models.

## Product decisions

- Use the destination-grouped plan board chosen as layout A: navigation on the left, grouped plan in the center, item inspector on the right, and a fixed summary/progress bar.
- Show scanned items immediately and enrich their suggestions incrementally. A manual destination, approval, or keep decision locks the item against late analysis results.
- Scan only direct children of the source. Analyze a source directory within fixed limits, but always move and undo it as one item.
- Discover destination directories to depth four. Classify each destination as category, collection, uncertain, or excluded. Only category destinations receive automatic proposals.
- Prefer existing destinations. Suggest one new child directory under the root or an existing category when needed; each folder proposal requires approval and the final depth may not exceed four.
- Keep source and library separate, non-overlapping, on the same volume. Same-folder Downloads organization is deferred.
- Extract text from up to three PDF pages, OCR the first page only when no text exists, and use bounded OCR for ambiguous images. Image-only comics and scores may require manual review.
- Let users type natural-language rules, inspect/edit the guided-generation result, and explicitly save it. Deterministic portions work without Foundation Models.
- Learn from successful, user-confirmed operations and bounded samples already present in category destinations. Existing content is weak evidence and never independently authorizes a move.
- Learning is event-driven and retractable. A successful undo invalidates the operation's learning sample. User-authored rules remain intact.
- Background download monitoring and rename suggestions are future adapters. They must submit work to the same coordinator and executor rather than moving or renaming directly.

## Safety and lifecycle

Classification only produces proposals. File operations originate from a versioned draft that is frozen after preflight and user confirmation. The executor logs each operation before moving it, records results item by item, and preserves a receipt for cancellation and partial failure.

Directory operations use a bounded recursive metadata manifest for undo verification. Undo processes completed operations in reverse order, refuses changed or occupied paths, deletes only app-created empty directories, and records each undo result persistently.

Slow source analysis and manifest preparation are cancellable. Final preflight is non-cancellable and short; each move performs a final snapshot check.

## Analysis budgets

- Text: read at most 1 MiB and retain 4,000 characters.
- Text PDF: first three pages and at most 6,000 characters.
- Scanned PDF: OCR first page only.
- Image: OCR only if still ambiguous; resize longest edge to at most 2,048 pixels.
- Source directory: inspect at most two levels and 200 entries, sample five representative files, and perform at most two OCR operations.
- Destination profile: inspect 50 direct entries; read at most three representative contents when disambiguation is needed.
- Session library learning: at most 60 new content samples and 12 OCR operations.
- Model destination selection: at most eight destinations per request and four hierarchical selection requests per item.

## Learning thresholds

A rule suggestion from explicit user decisions requires at least three distinct items across two execution sessions within 90 days. A suggestion from existing library contents requires at least eight distinct valid samples with a shared non-generic feature and no observed conflicting destination. File type alone is not sufficient.

## Acceptance

- A user can choose two folders, see an incremental grouped draft, understand every source-to-destination mapping, confirm selected items, execute, restart, inspect history, and undo eligible moves.
- Late AI output never overwrites a manual decision.
- A directory such as `Comic/01.jpg` and `Comic/02.jpg` remains one move operation.
- Nested same-named destinations are distinguishable by full relative path.
- Failed or skipped operations do not become positive learning samples; retries do not duplicate samples; successful undo retracts them.
- Foundation Models unavailable mode still supports deterministic rules, review, execution, history, and undo.

