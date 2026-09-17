---
description: Language-agnostic production standards for all code generation and reviews.
applyTo: '**'
---

# Instruction Compliance (Highest Priority)

These rules override speed, scope reduction, and momentum. They apply to every task.

1. **Complete means complete.** When the user says resolve, fix all, finish, or complete, every stated requirement must be done before the task is considered finished.
2. **No partial shipping.** Do not commit, push, or report success while any stated requirement remains open. If a requirement cannot be completed, stop and report the blocker before shipping partial work.
3. **Requirement traceability.** Before any commit, push, or completion report, include a requirement-by-requirement status table: Requirement | Status | Evidence.
4. **Explicit gates only.** Do not commit or push unless the user explicitly asked for it in that task, except where this file's commit standards apply to completed work the user already requested be finished end-to-end.
5. **Verify, do not assume.** A green build is not proof that every requirement is satisfied. Re-check the original instruction list before declaring done.
6. **Always manually verify code.** After implementing changes, verify the work builds correctly or functions as expected before concluding the task.
7. **Follow instructions to the letter.** User instructions are mandatory constraints, not suggestions. Do not reinterpret them into a smaller task without explicit approval.
8. **Granular, ordered commits.** Follow the multi-commit, dependency-ordered, detailed commit standards. Never create single monolithic commits for multi-phase or multi-domain work.

# Operational Protocol
Execute every task in this order:

1. **Audit** — List all files, modules, and components required.
2. **Blueprint** — Outline a concise architectural plan before writing code.
3. **Execution** — Deliver complete, production-ready code. No snippets, placeholders (`TODO`, `pass`, `...`), or stubs.
4. **Autonomy** — Resolve missing context or dependencies using the standard library or canonical practices.

# Testing Policy
- This repository has **no automated test suite**. Do not recreate `Tests/`, `PixelNOWTests`, or CI test jobs unless the user explicitly asks.
- **Never run tests** (`xcodebuild test`, `swift test`, CI test jobs, or equivalent) unless the user explicitly asks to run tests in that task.
- **Never add tests** unless the user explicitly asks for tests.
- Builds (`xcodebuild build`) are fine when needed to verify compilation.

# Build Artifact Discipline
- For this Xcode project, use Xcode/XcodeBuildMCP only for builds and runs. Do not use SwiftPM commands as build/test/run shortcuts unless the user explicitly overrides this instruction for a specific task.
- Run SwiftPM commands from the repository root unless a task explicitly requires otherwise.
- Use `--scratch-path .build/shared` for SwiftPM commands that generate build state, including `swift build` and `swift run`. Do not run `swift test` unless the user explicitly requests it.
- Do not run package-local SwiftPM commands that create package-specific `.build` directories. Use the root `Package.swift` with the shared scratch path instead.
- After SwiftPM-heavy tasks, run `scripts/report-spm-build-size.sh` to check generated build size and duplicated binary artifact extractions.
- If generated SwiftPM files exceed the warning threshold or duplicate `artifacts/sentry-cocoa` directories appear, run `scripts/clean-spm-builds.sh`, then rerun builds with `--scratch-path .build/shared`.
- Never commit generated build artifacts.

# Graphify Knowledge Graph

Graphify turns this codebase, documentation, and external reference assets into a queryable, persistent knowledge graph with AST structural extraction, semantic extraction, Louvain community detection, god node analysis, and traversal tools.

## Fast-Path: Graph-First Codebase Exploration
Before scanning files or running unstructured grep searches, check whether `graphify-out/graph.json` exists in the repository root:
1. **Always check `graphify-out/graph.json` first.**
2. If `graphify-out/graph.json` exists and the task involves understanding architecture, tracing dependencies, locating entry points, or answering natural-language questions ("How does X work?", "What calls Y?", "Trace data flow through Z"):
   - **Skip full re-extraction and detection.** Jump directly to querying the knowledge graph.
   - Use `graphify query`, `graphify path`, or `graphify explain`.
3. If `graphify-out/graph.json` does not exist or files have changed, execute the appropriate build or incremental update pipeline below.

---

## Command Reference & CLI Options

```bash
# Full Pipeline Execution
graphify .                                            # Run full pipeline on current repository root
graphify <path>                                       # Run full pipeline on specific directory path
graphify <url>                                        # Clone remote repo and build knowledge graph
graphify <url1> <url2> ...                            # Clone multiple repos and merge into one cross-repo graph

# Extraction & Model Tuning
graphify <path> --mode deep                           # Deep extraction with aggressive inferred edges & latent couplings
graphify <path> --update                              # Incremental re-extraction (processes only new/modified files, prunes deleted)
graphify <path> --directed                            # Construct directed graph (DiGraph, source -> target edge preservation)
graphify <path> --whisper-model <model>               # Audio/video transcription model (e.g. base, medium, large)

# Analysis & Clustering
graphify <path> --cluster-only                        # Rerun Louvain clustering and report generation on existing graph

# Ingestion & Automation
graphify add <url> [--author "Name"] [--contributor "Name"]  # Fetch URL (web, YouTube, Twitter/X, arXiv, PDF) into ./raw and update
graphify <path> --watch                               # Continuous file-watcher with debounce; rebuilds AST automatically

# Traversal & Queries
graphify query "<question>"                           # BFS traversal for broad nearest-neighbor context
graphify query "<question>" --dfs                     # DFS traversal for tracing deep call or dependency chains (up to depth 6)
graphify query "<question>" --budget 2000             # Cap response output tokens (default 2000)
graphify path "<conceptA>" "<conceptB>"               # Shortest path between two concepts or symbols
graphify explain "<concept>"                          # Plain-language explanation of a node and its structural neighborhood

# Export Formats
graphify export html                                  # Generate interactive graph.html (default)
graphify <path> --no-viz                              # Skip visualization generation, output only graph.json + GRAPH_REPORT.md
graphify export obsidian [--dir <path>]               # Generate Obsidian markdown vault (default graphify-out/obsidian)
graphify export wiki                                  # Generate agent-crawlable wiki (index.md + community articles)
graphify export svg                                   # Export static graph.svg
graphify export graphml                               # Export graph.graphml for Gephi or yEd
graphify export neo4j [--push bolt://localhost:7687]  # Export Cypher script or push directly to Neo4j instance
graphify export falkordb [--push falkordb://localhost:6379] # Export OpenCypher or push to FalkorDB
graphify <path> --mcp                                 # Launch stdio Model Context Protocol (MCP) server for live tool queries
graphify benchmark                                    # Run token reduction benchmark (corpora > 5000 words)

# Lifecycle & Git Hooks
graphify hook install                                 # Install post-commit git hook to auto-update AST on commit
graphify hook status                                  # Verify post-commit git hook status
graphify hook uninstall                               # Remove post-commit git hook
graphify agents install                               # Install graphify instructions into project AGENTS.md
graphify agents uninstall                             # Remove graphify section from AGENTS.md
```

---

## Querying and Traversal (`query`, `path`, `explain`)

### 1. Constrained Query Expansion (Mandatory Pre-Traversal Step)
The literal query matcher uses case-folded substring and IDF matching without automatic stemming or synonym expansion. To avoid zero-hit collapses when query phrasing differs from code identifiers:
1. Extract the node vocabulary from `graphify-out/graph.json`:
   ```bash
   $(cat graphify-out/.graphify_python) -c "
   import json, re
   from pathlib import Path
   data = json.loads(Path('graphify-out/graph.json').read_text(encoding='utf-8'))
   vocab = set()
   for n in data['nodes']:
       for c in re.findall(r'[^\W\d_]+', n.get('label','') or '', re.UNICODE):
           parts = re.findall(r'[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+', c) or [c]
           for p in parts:
               t = p.lower()
               if 3 <= len(t) <= 30:
                   vocab.add(t)
   Path('graphify-out/.vocab.txt').write_text('\n'.join(sorted(vocab)), encoding='utf-8')
   print(f'vocab: {len(vocab)} tokens')
   "
   ```
2. Read `graphify-out/.vocab.txt` and select up to 12 matching tokens strictly present in the file. Do not hallucinate or inject terms not present in the graph vocabulary.
3. Print the auditable expansion: `Query expanded to (from graph vocab, N tokens): [token1, token2, ...]`.
4. Use the joined token string as the query input.

### 2. Traversal Execution
- **CLI Traversal:**
  ```bash
  graphify query "<expanded_terms>" [--dfs] [--budget 2000]
  graphify path "<NodeA>" "<NodeB>"
  graphify explain "<NodeName>"
  ```
- **Inline NetworkX Fallback (when CLI binary is not directly available):**
  - Load `graphify-out/graph.json` via `networkx.readwrite.json_graph.node_link_graph(data, edges='links')`.
  - For BFS: explore neighbors layer by layer up to depth 3 from the top term-matching nodes.
  - For DFS: trace paths up to depth limit 6.
  - For `path`: evaluate `networkx.shortest_path(G, source, target)`.
  - For `explain`: retrieve node attributes (`source_file`, `source_location`, `file_type`) and neighbor relations.
  - Cite `source_file` and `source_location` in all answers. Never hallucinate edges.

### 3. Continuous Learning & Work Memory Loop
- **Saving results back to the graph:**
  After completing an answer or explanation, save the finding back to the graph to improve future query relevance:
  ```bash
  $(cat graphify-out/.graphify_python) -m graphify save-result \
    --question "<original_question>" \
    --answer "<full_answer_including_vocab_trace>" \
    --type query \
    --nodes <cited_nodes> \
    --outcome useful
  ```
  - `--outcome`: `useful` (adds nodes as preferred sources), `dead_end` (avoids dead pathways), `corrected` (requires `--correction "<true_answer>"`).
- **Session startup memory:**
  At the beginning of graph-assisted exploration, run `graphify reflect --if-stale` and review `graphify-out/reflections/LESSONS.md` to identify preferred source nodes, known dead ends, and past corrections.

---

## Full Pipeline Lifecycle & Execution Steps

When running a full build or rebuild, execute each step sequentially:

### Step 1: Interpreter Resolution
Detect and persist the active Python environment with graphify installed:
```bash
PYTHON=""
GRAPHIFY_BIN=$(which graphify 2>/dev/null)
if [ -z "$PYTHON" ] && command -v uv >/dev/null 2>&1; then
    _UV_PY=$(uv tool run --from graphifyy python -c "import sys; print(sys.executable)" 2>/dev/null)
    if [ -n "$_UV_PY" ]; then PYTHON="$_UV_PY"; fi
fi
if [ -z "$PYTHON" ] && [ -n "$GRAPHIFY_BIN" ]; then
    _SHEBANG=$(head -1 "$GRAPHIFY_BIN" | tr -d '#!')
    case "$_SHEBANG" in
        *[!a-zA-Z0-9/_.@-]*) ;;
        *) "$_SHEBANG" -c "import graphify" 2>/dev/null && PYTHON="$_SHEBANG" ;;
    esac
fi
if [ -z "$PYTHON" ]; then PYTHON="python3"; fi
mkdir -p graphify-out
"$PYTHON" -c "import sys; open('graphify-out/.graphify_python', 'w', encoding='utf-8').write(sys.executable)"
echo "$(cd . && pwd)" > graphify-out/.graphify_root
```
*Note: All subsequent Python commands use `$(cat graphify-out/.graphify_python)`.*

### Step 2: Corpus Detection
```bash
$(cat graphify-out/.graphify_python) -c "
import json
from graphify.detect import detect
from pathlib import Path
result = detect(Path('.'))
Path('graphify-out/.graphify_detect.json').write_text(json.dumps(result, ensure_ascii=False), encoding='utf-8')
print(f'Detected {result[\"total_files\"]} files')
"
```
- Print category breakdown (`code`, `document`, `paper`, `image`, `video`).
- If `skipped_sensitive` is non-empty, display the flagged file count and file names.
- If `total_words` > 2,000,000 or `total_files` > 500: rank top 5 first-level subdirectories and confirm scope before proceeding (or suggest `--no-cluster`).

### Step 2.5: Video & Audio Transcription (if video files detected)
If media files exist in `files['video']`:
1. Generate a one-sentence domain hint from top god nodes / analysis labels (or fallback to `"Use proper punctuation and paragraph breaks."`).
2. Export `GRAPHIFY_WHISPER_PROMPT` and `GRAPHIFY_WHISPER_MODEL` (e.g. `base`).
3. Transcribe via `graphify.transcribe.transcribe_all`, save to `graphify-out/.graphify_transcripts.json`, and feed the resulting transcript documents into Step 3.

### Step 3: Entity & Relationship Extraction
Extraction runs AST structural parsing and semantic extraction in parallel:
- **Part A (Structural AST Extraction):**
  Extract code AST nodes and edges deterministically (no LLM, no API keys, zero cost):
  ```bash
  $(cat graphify-out/.graphify_python) -c "
  import json
  from graphify.extract import collect_files, extract
  from pathlib import Path
  detect = json.loads(Path('graphify-out/.graphify_detect.json').read_text(encoding='utf-8'))
  code_files = []
  for f in detect.get('files', {}).get('code', []):
      code_files.extend(collect_files(Path(f)) if Path(f).is_dir() else [Path(f)])
  if code_files:
      result = extract(code_files, cache_root=Path('.'))
      Path('graphify-out/.graphify_ast.json').write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')
  else:
      Path('graphify-out/.graphify_ast.json').write_text(json.dumps({'nodes':[],'edges':[],'input_tokens':0,'output_tokens':0}), encoding='utf-8')
  "
  ```
- **Part B (Semantic Extraction for Docs, Papers, and Images):**
  - **No API key requirement:** graphify never blocks on or requires external keys for code. For non-code documents, it uses `GEMINI_API_KEY`/`GOOGLE_API_KEY` if present (`graphify.llm.extract_corpus_parallel(files, backend="gemini")`); otherwise, the host agent performs extraction via chunked subagents.
  - If no docs/papers/images exist, immediately write an empty `.graphify_semantic.json` and proceed to Part C.
  - Chunk size: 20-25 files per chunk (images processed individually).
  - Cache validation: verify against `references/extraction-spec.md` using `graphify.cache.check_semantic_cache`. Only uncached files are dispatched.
  - Extraction rules:
    - Edge categories: `EXTRACTED` (confidence `1.0`), `INFERRED` (discrete score from `{0.95, 0.85, 0.75, 0.65, 0.55}`, never `0.5`), `AMBIGUOUS` (`0.1-0.3`).
    - `file_type` must strictly be one of: `code`, `document`, `paper`, `image`, `rationale`, `concept`.
    - `calls` edges: source must be the caller and target must be the callee within the same language. Cross-language call edges are forbidden.
    - Node ID format: `{repo_relative_stem}_{entity_name}` lowercase with `_` separators (e.g. `viewmodel_gameviewmodel_launchgame`). Never append chunk or sequence IDs.
    - `source_file` must be copied verbatim and absolute from the input list.
    - Hyperedges: group 3 or more nodes participating in a coherent flow or interface pattern (maximum 3 hyperedges per chunk).
  - Save extracted chunks and cache via `save_semantic_cache`.
- **Part C (Merge AST + Semantic):**
  Merge deduplicated nodes and combine all edges into `graphify-out/.graphify_extract.json`.

### Step 4: Graph Assembly, Clustering, and Analysis
```bash
$(cat graphify-out/.graphify_python) -c "
import json
from graphify.build import build_from_json
from graphify.cluster import cluster, score_all
from graphify.analyze import god_nodes, surprising_connections, suggest_questions
from graphify.report import generate
from graphify.export import to_json
from pathlib import Path

extraction = json.loads(Path('graphify-out/.graphify_extract.json').read_text(encoding='utf-8'))
detection  = json.loads(Path('graphify-out/.graphify_detect.json').read_text(encoding='utf-8'))
G = build_from_json(extraction, root='.', directed=False)
if G.number_of_nodes() == 0:
    raise SystemExit('ERROR: Graph is empty - extraction produced no nodes.')

communities = cluster(G)
cohesion = score_all(G, communities)
gods = god_nodes(G)
surprises = surprising_connections(G, communities)
labels = {cid: f'Community {cid}' for cid in communities}
questions = suggest_questions(G, communities, labels)

# Shrink guard (#479): prevent overwriting existing graph with a smaller node set
if not to_json(G, communities, 'graphify-out/graph.json'):
    raise SystemExit('ERROR: refused to shrink graphify-out/graph.json.')

report = generate(G, communities, cohesion, labels, gods, surprises, detection, {'input': extraction.get('input_tokens',0), 'output': extraction.get('output_tokens',0)}, '.', suggested_questions=questions)
Path('graphify-out/GRAPH_REPORT.md').write_text(report, encoding='utf-8')
analysis = {'communities': {str(k): v for k, v in communities.items()}, 'cohesion': {str(k): v for k, v in cohesion.items()}, 'gods': gods, 'surprises': surprises, 'questions': questions}
Path('graphify-out/.graphify_analysis.json').write_text(json.dumps(analysis, indent=2, ensure_ascii=False), encoding='utf-8')
"
```

### Step 4.5: Graph Health Check
Run non-destructive diagnostics via `graphify.diagnostics.diagnose_extraction`:
- Audit dangling endpoints, missing endpoints, self-loops, and collapsed edges.
- Surface any warnings in the report without terminating execution.

### Step 5: Community Labeling
1. Review `graphify-out/.graphify_analysis.json` and curate concise 2-5 word descriptive labels for each community cluster (e.g. `Game Stream Session`, `WebRTC Pipeline`, `Input Injection`).
2. Update `GRAPH_REPORT.md`, write `graphify-out/.graphify_labels.json`, and re-export `graph.json` with embedded community labels via `to_json(G, communities, 'graphify-out/graph.json', community_labels=labels)`.

### Step 6: Artifact Generation & Exports
- Generate HTML visualization: `graphify export html` (automatically aggregates to community view if nodes exceed 5,000).
- If `--obsidian`: `graphify export obsidian [--dir <path>]`.
- If `--wiki`: `graphify export wiki`.
- If `--neo4j` or `--neo4j-push`: `graphify export neo4j [--push <uri>]`.
- If `--falkordb` or `--falkordb-push`: `graphify export falkordb [--push <uri>]`.
- If `--svg`: `graphify export svg`.
- If `--graphml`: `graphify export graphml`.

### Step 7: Manifest, Cost Tracking, and Cleanup
1. Save portable relative manifest via `save_manifest(..., root='.')` using `_stamped_manifest_files`. Ensure unextracted or failed semantic files remain unstamped for future re-extraction.
2. Update cumulative token cost tracking in `graphify-out/cost.json`.
3. Clean temporary files:
   ```bash
   rm -f graphify-out/.graphify_detect.json graphify-out/.graphify_extract.json graphify-out/.graphify_ast.json graphify-out/.graphify_semantic.json graphify-out/.graphify_analysis.json
   find graphify-out -maxdepth 1 -name '.graphify_chunk_*.json' -delete 2>/dev/null
   rm -f graphify-out/.needs_update 2>/dev/null || true
   ```
4. Surface summary in conversation: output God Nodes, Surprising Connections, and the most compelling Suggested Question to guide subsequent exploration.

---

## Incremental Updates & Maintenance

### Incremental Re-Extraction (`--update`)
Use after modifying, adding, or deleting source files:
1. Run `detect_incremental(Path('.'))` to identify `new_files` and `deleted_files`.
2. **Code-only bypass:** If all modified files are code files (`.swift`, `.py`, `.ts`, etc.), skip semantic LLM extraction completely. Run only Step 3 Part A AST on the changed files.
3. Merge cleanly via `build_merge(..., graph_path='graphify-out/graph.json', prune_sources=deleted, root='.', directed=IS_DIRECTED)`. Note: changed files are replaced automatically by source file attribution; only deleted files are passed to `prune_sources`.
4. Re-run Louvain clustering, analysis, and report generation.
5. Print graph diff summary using `graphify.analyze.graph_diff(G_old, G_new)`.

### Clustering Only (`--cluster-only`)
To re-group communities or re-generate reports without modifying underlying extracted nodes:
```bash
graphify cluster-only .
```
*Note: Do not re-run intermediate extraction steps; `cluster-only` executes self-contained clustering on `graphify-out/graph.json` directly.*

### File Watcher (`--watch`)
Run in a background process or terminal during active development:
```bash
$(cat graphify-out/.graphify_python) -m graphify.watch . --debounce 3
```
- Automatically triggers AST extraction, build, and clustering on code modifications.
- Writes `graphify-out/.needs_update` when documentation or media changes occur, signaling that semantic re-extraction is required.

---

## Multi-Repo & Subfolder Operations

### Cloning & Cross-Repo Merging
```bash
# Clone repositories into ~/.graphify/repos/
graphify clone https://github.com/<owner>/<repoA>
graphify clone https://github.com/<owner>/<repoB>

# Merge individual graphs into a unified cross-repo graph
graphify merge-graphs \
  ~/.graphify/repos/<owner>/<repoA>/graphify-out/graph.json \
  ~/.graphify/repos/<owner>/<repoB>/graphify-out/graph.json \
  --out graphify-out/cross-repo-graph.json
```

### Monorepo & Isolated Subfolders
To avoid collisions in shared `graphify-out/`:
```bash
graphify extract ./subfolderA/
graphify extract ./subfolderB/
graphify merge-graphs ./subfolderA/graphify-out/graph.json ./subfolderB/graphify-out/graph.json --out graphify-out/graph.json
```

---

## MCP Server Integration
To expose the knowledge graph directly to LLM agent orchestrators (Claude Desktop, IDE agents, MCP clients):
```bash
$(cat graphify-out/.graphify_python) -m graphify.serve graphify-out/graph.json
```
Exposes tools:
- `query_graph(query)`
- `get_node(node_id)`
- `get_neighbors(node_id)`
- `get_community(community_id)`
- `god_nodes()`
- `graph_stats()`
- `shortest_path(source, target)`

---

## Operational & Honesty Rules
1. **Never fabricate edges:** If a relationship is plausible but unverified, classify as `INFERRED` with appropriate confidence or mark as `AMBIGUOUS`.
2. **Preserve edge directionality:** Always ensure `calls` and dependency relationships point from caller (`source`) to callee (`target`).
3. **Never bypass corpus check warnings:** Address corpus scale limits when files > 500 or words > 2,000,000.
4. **Transparent metrics:** Report raw cohesion scores and exact token costs in `GRAPH_REPORT.md` and `cost.json`.
5. **Shrink Guard Protection:** Never overwrite `graph.json` if the new node count is smaller than the existing graph without explicit user override (`--force`).
6. **Large graph visualization safety:** Warn before rendering HTML visualization on graphs with more than 5,000 nodes; use aggregated community views.

# Coding Standards

## General
- **Self-Documenting:** Names and structure must convey intent. No explanatory inline comments.
- **Hermetic:** Every file includes all imports and dependencies. Must compile/run as-is.
- **Complete:** All functions and methods contain final, working logic. No mocks or no-ops.
- **No Folded Code:** Folding code is strictly forbidden.

## Migration & Conversion
- **No Stubs:** Never use stubs when migrating or converting code.
- **In-Place Conversion:** Always convert the existing implementation in place.
- **No Wrappers:** Do not use wrappers, shims, adapters, or compatibility layers during migration or conversion.
- **Remove Legacy Files:** Delete the old `.mm` and `.h` files after migration or conversion.
- **Trace Blockers:** Always trace and convert or migrate blockers during migration or conversion.
- **Migrate Blockers:** Always migrate blockers instead of bypassing, stubbing, or deferring them.

## Resource & State
- **Lifecycle:** Explicitly manage memory, connections, and handles via the language's native paradigm (RAII, context managers, ownership, etc.).
- **Immutable by Default:** Use language-native constraints (`const`, `readonly`, `final`). Mutable state must be minimal and scoped.

## Error Handling
- **Explicit:** Handle all edge cases idiomatically (Result/Option types, caught exceptions, multiple returns).
- **No Panics:** Never use forceful unwraps or unhandled crash equivalents. Failures must propagate or degrade gracefully.

## Quality
- **Strict Typing:** Use static/strict types throughout. Avoid `any` or dynamic types unless architecturally required.
- **Zero Warnings:** Code must pass the strictest linter and compiler settings cleanly.

# Commit Standards

Every commit in this repository must adhere to strict granularity, dependency ordering, and detailed documentation. Single monolithic commits covering multiple components or phases are strictly prohibited.

## 1. Granular & Atomic Commits
- **No Monolithic Commits:** Never combine multi-phase, multi-component, or multi-domain changes into a single large commit.
- **Atomic Isolation:** Break work into individual commits by phase, subsystem, or logical layer (e.g., core types, wire framing, pipeline integration, telemetry, submodule bump).
- **Compilable States:** Every intermediate commit must build cleanly on its own without breaking the tree.

## 2. Strict Chronological Dependency Ordering
Commits must be created in logical dependency order from foundational primitives up to high-level consumers:
1. **ABI & Primitives:** Core memory layouts, struct strides, enums, raw values, and low-level data structures.
2. **Wire & Protocol:** Protocol framing, packet payload builders/parsers, stream configurations, and opcodes.
3. **Telemetry & Feedback:** Feedback loops, metrics collectors, latency timers, and QoS dispatchers.
4. **Pipelines & Controllers:** High-level pipeline wiring, decoders/renderers, governors, and business logic.
5. **Submodule References & Glue:** Submodule pointer updates and parent repository integration commits.

*Cross-Repository / Submodule Rule:* When changes span both a submodule (e.g., `GFN/`) and the parent repository (`PixelNOW`), all submodule commits must be created, verified, and pushed upstream first. The parent repository then commits its changes and updates the submodule pointer in subsequent commits.

## 3. Commit Message Structure & Detail
Every commit message must follow this exact structure:

```
<type>(<scope>): <concise imperative summary>

- <detailed bullet itemizing specific structs, enums, or functions modified/added>
- <exact byte layouts, ABI strides, bit flags, raw values, or opcodes changed>
- <algorithmic or architectural rationale for behavior adjustments>
- <component interactions or integrations wired up>
```

- **Header Tag:** Prefix with a standard conventional type: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `perf:`, `test:`, or `style:`. Include an explicit parenthetical scope indicating the subsystem (e.g., `feat(nvst):`, `fix(video):`, `chore(submodule):`).
- **Subject Line:** Concise, present-tense, imperative mood, under 72 characters, no trailing period.
- **Blank Line:** Exactly one blank line between the header and the bulleted body.
- **Detailed Body:** Bulleted list itemizing every affected symbol, memory stride (e.g., `120-byte ABI layout`), opcode (e.g., `0x0327`), algorithm threshold (e.g., `loss >= 10%`), and cross-component hook. Never use empty bodies or vague one-liners (e.g., "fix various bugs").

## 4. Push and Traceability Discipline
- **Traceability Table:** Always provide a requirement-by-requirement status table (`Requirement | Status | Evidence`) before committing, pushing, or declaring completion.
- **Build Verification:** Verify compilation (`xcodebuild build` or project build command) before committing.
- **Push Policy:** Push all completed commits to the current branch's upstream remote (`git push origin <branch>`).

# Release Process
When instructed to create a new GitHub release, strictly follow these steps in order:
1. **Update Version:** Bump the version using `agvtool new-marketing-version <version>` and `agvtool new-version -all <build>`.
2. **Commit & Push:** Commit all outstanding changes (including the version bump) and push to the remote repository.
3. **Write Patch Notes:** Create a text file containing the patch notes for the release (e.g., `patch_notes.txt`).
4. **Compile:** Compile the release configuration of the app using `xcodebuild -scheme PixelNOW -project PixelNOW.xcodeproj -configuration Release clean build`.
5. **Compress:** Do NOT use the standard `zip` command as it breaks the macOS code signature. Navigate to the release build directory and use `ditto` to compress the app bundle: `ditto -c -k --keepParent PixelNOW.app PixelNOW-<version>-macOS.zip`
6. **Upload to GitHub:** Use the GitHub CLI to create the release and upload the compressed app bundle: `gh release create v<version> PixelNOW-<version>-macOS.zip -F <patch_notes_file> -t "PixelNOW <version>"`

# Workspace Cleanliness
- **No Leftover Trash:** Never leave random, unneeded artifacts (e.g., temporary scripts, `build.log`, `.txt` dumps) in the workspace root or project directories. Clean them up immediately after use. If you absolutely need a scratchpad or temporary file, place it strictly in the designated artifact scratch directory (`<appDataDir>/brain/<conversation-id>/scratch/`).
- **No Python Scripts:** Do not generate or execute Python scripts to accomplish tasks (like parsing files or patching code). Rely on existing tools, native shell commands (`awk`, `sed`, `grep`), or perform the task directly.
