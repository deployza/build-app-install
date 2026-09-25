# -----------------------------------------------------------------------------
# VENDORED FROM GRAPHIFY — DO NOT EDIT TO CHANGE BEHAVIOUR.
#
# Source:   graphifyy 0.9.48
#           graphify/extractors/markdown.py   (extract_markdown and helpers)
#           graphify/extractors/base.py       (_file_stem)
#           graphify/ids.py                   (make_id, normalize_id)
#           graphify/security.py              (sanitize_metadata and helpers)
#           graphify/detect.py                (_SKIP_DIRS)
# Licence:  Apache-2.0 (graphifyy ships Apache-2.0 + MIT; see its LICENSE files)
# Vendored: 2026-08-27
#
# WHY THIS IS COPIED RATHER THAN IMPORTED
#
# graphify's Markdown extractor is exactly what we want — deterministic, no LLM,
# no network, 0 tokens — but reaching it means importing FOUR private symbols
# (`_file_stem`, `_make_id`, `_SKIP_DIRS`, and the module global
# `_XAML_ACTIVE_EXTRACT_ROOT`). Upstream owes us nothing for any of them, and
# graphify is pre-1.0 and moving: 0.9.48 and 0.9.50 already differ elsewhere.
# Worse, one of those couplings failed SILENTLY — `_active_scan_root()` read the
# global with `getattr(..., None)`, so a rename upstream would not raise, it
# would just quietly stop resolving links.
#
# Copying converts an unmanaged upstream risk into ~500 lines we own and can
# test. The behaviour here is byte-for-byte identical to graphify 0.9.48's — that
# is asserted by the check in `mcp-md-graph --self-test`, which diffs this
# module's output against the installed library's on a real repo.
#
# WHAT THIS DOES *NOT* DECOUPLE US FROM
#
# The `graph.json` node-link schema. `graphify global add` reads what we write,
# so a schema change upstream still breaks us. Vendoring the extractor does not
# change that, and nothing here should be read as claiming it does.
#
# THE ONE DELIBERATE DEVIATION
#
# Upstream reads the scan root from a module global that `extract()` sets.
# Here it is an explicit `scan_root` argument to `extract_markdown()`. Same
# behaviour, passed rather than smuggled — and it removes the silent-failure mode
# described above. Everything else is faithful.
#
# RE-SYNCING ON A GRAPHIFY UPGRADE
#
# This file does NOT auto-update with the venv. On a `GRAPHIFY_VERSION` bump, run
# `mcp-md-graph --self-test`: it compares this module against the newly
# installed library and fails if they have diverged. Then either re-vendor from
# the new version or record why the divergence is acceptable.
# -----------------------------------------------------------------------------
"""Structural Markdown extraction: page nodes, heading tree, reference edges."""
from __future__ import annotations

import html
import os
import re
import unicodedata
from pathlib import Path
from typing import Any, Mapping

# ---------------------------------------------------------------------------
# from graphify/ids.py
# ---------------------------------------------------------------------------


def normalize_id(s: str) -> str:
    r"""Normalize a single ID string to its canonical form.

    Guarantees: idempotent; result contains only ``\w`` and ``_``; caseless-stable
    (``normalize_id(s) == normalize_id(s.casefold())``).

    casefold and NFKC do not commute and neither is a fixpoint of the other:
    casefolding a char can expand it into a base letter plus a combining mark
    (``İ`` -> ``i`` + U+0307), and NFKC can then recompose that mark with an
    adjacent one. So iterate casefold-then-NFKC to a fixpoint (casefold FIRST, so
    a caller that pre-casefolds lands on the same fixpoint), bounded by a hard cap
    as a termination guard, and only then apply the ``[^\w]+`` filter.
    """
    cur = s
    for _ in range(6):
        nxt = unicodedata.normalize("NFKC", cur.casefold())
        if nxt == cur:
            break
        cur = nxt
    cur = re.sub(r"[^\w]+", "_", cur, flags=re.UNICODE)
    cur = re.sub(r"_+", "_", cur)
    return cur.strip("_")


def make_id(*parts: str) -> str:
    """Build a canonical node ID from one or more name parts."""
    return normalize_id("_".join(p.strip("_.") for p in parts if p))


_make_id = make_id


# ---------------------------------------------------------------------------
# from graphify/extractors/base.py
# ---------------------------------------------------------------------------


def _file_stem(path: Path) -> str:
    """Stem used as the node-ID prefix for a file and its symbols.

    Every path segment is preserved (not just the immediate parent), so
    same-named files in different directories get distinct IDs:

        docs/v1/api/README.md -> docs_v1_api_readme
        docs/v2/api/README.md -> docs_v2_api_readme

    Returns "" for a path with no name (``Path('.')``), which keeps
    ``with_suffix("")`` from raising on an empty name.
    """
    if not path.name:
        return ""
    return path.with_suffix("").as_posix()


# ---------------------------------------------------------------------------
# from graphify/security.py
# ---------------------------------------------------------------------------

_CONTROL_CHAR_RE = re.compile(r"[\x00-\x1f\x7f]")
_METADATA_MAX_VALUE_LEN = 512
_METADATA_MAX_LIST_ITEMS = 50


def _sanitize_metadata_string(value: object) -> str:
    """Return a control-character-free, HTML-escaped, bounded string."""
    text = _CONTROL_CHAR_RE.sub("", str(value))
    text = html.escape(text, quote=True)
    if len(text) > _METADATA_MAX_VALUE_LEN:
        text = text[:_METADATA_MAX_VALUE_LEN]
    return text


def _sanitize_metadata_value(value: object) -> object:
    """Sanitize a metadata value while preserving simple JSON-compatible types."""
    if isinstance(value, bool):
        # bool is a subclass of int — must be checked first to avoid coercion.
        return value
    if isinstance(value, str):
        return _sanitize_metadata_string(value)
    if isinstance(value, dict):
        return sanitize_metadata(value)
    if isinstance(value, (list, tuple)):
        return [_sanitize_metadata_value(i) for i in value[:_METADATA_MAX_LIST_ITEMS]]
    if isinstance(value, (int, float)) or value is None:
        return value
    return _sanitize_metadata_string(value)


def sanitize_metadata(metadata: "Mapping[str, Any] | None") -> "dict[str, object]":
    """Sanitize metadata keys and values before graph export.

    Frontmatter is author-controlled text that ends up in the graph and is
    rendered by consumers, so it is kept JSON-compatible, stripped of control
    characters, HTML-escaped, and capped in length. Entries whose key sanitizes
    to empty are dropped.
    """
    if metadata is None:
        return {}
    result: dict[str, object] = {}
    for key, value in metadata.items():
        clean_key = _sanitize_metadata_string(key)
        if not clean_key:
            continue
        result[clean_key] = _sanitize_metadata_value(value)
    return result


# ---------------------------------------------------------------------------
# from graphify/detect.py — the corpus boundary the scanner draws. Only used to
# prune the wikilink index walk below.
# ---------------------------------------------------------------------------

_SKIP_DIRS = {
    "*.egg-info", ".angular", ".cache", ".eggs", ".git", ".graphify", ".idea",
    ".mypy_cache", ".next", ".nox", ".nuxt", ".obsidian", ".parcel-cache",
    ".pytest_cache", ".ruff_cache", ".serverless", ".smart-env", ".svelte-kit",
    ".terraform", ".tox", ".turbo", ".venv", ".worktrees", "__pycache__",
    "__snapshots__", "build", "dist", "dist-protected", "graphify-out",
    "lcov-report", "lib64", "node_modules", "out", "site-packages",
    "storybook-static", "target", "venv", "visual-test", "visual-tests",
}


# ---------------------------------------------------------------------------
# from graphify/extractors/markdown.py
# ---------------------------------------------------------------------------

_MD_INLINE_LINK_RE = re.compile(r'(?<!\!)\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+[^)]*)?\)')
_MD_REF_DEF_RE = re.compile(r'^\s{0,3}\[[^\]]+\]:\s*<?([^\s>]+)>?')
_MD_WIKILINK_RE = re.compile(r'(?<!\!)\[\[([^\]|#]+)(?:[#|][^\]]*)?\]\]')

_MD_LINKABLE_EXTS = {".md", ".mdx", ".qmd", ".markdown", ".rst", ".txt"}

# A YAML frontmatter block is only frontmatter when the opening `---` is the very
# first line. A `---` further down is a horizontal rule. Bounded so a file that
# opens a fence and never closes it cannot swallow the whole document.
_MD_FRONTMATTER_CLOSE = ("---", "...")
_MD_FRONTMATTER_MAX_LINES = 200

# Flat `key: value` fallback, used only when PyYAML is unavailable.
_MD_FM_SCALAR_RE = re.compile(r'^([A-Za-z0-9_][A-Za-z0-9_\-. ]*):\s*(.*)$')

# Wikilink index, keyed by resolved scan root. See _vault_lookup.
_MD_LINK_INDEX_CACHE: "dict[str, dict[str, list[tuple[int, str, Path]]]]" = {}


def clear_link_index_cache() -> None:
    """Drop the wikilink index. Call between scans of different trees."""
    _MD_LINK_INDEX_CACHE.clear()


def _split_frontmatter(lines: "list[str]") -> "tuple[list[str], int]":
    """Split leading YAML frontmatter off *lines*.

    Returns ``(frontmatter_lines, body_start_index)``; ``([], 0)`` when there is
    none, so the caller parses from line 0 exactly as before.
    """
    if not lines or lines[0].strip() != "---":
        return [], 0
    limit = min(len(lines), _MD_FRONTMATTER_MAX_LINES + 1)
    for i in range(1, limit):
        if lines[i].strip() in _MD_FRONTMATTER_CLOSE:
            return lines[1:i], i + 1
    # Unterminated fence: treat the `---` as ordinary content.
    return [], 0


def _parse_frontmatter_fallback(fm_lines: "list[str]") -> dict:
    """Flat `key: value` parser for when PyYAML is not installed.

    Nested blocks and list items are skipped rather than guessed at.
    """
    out: dict = {}
    for raw in fm_lines:
        if not raw[:1].strip():
            continue  # indented -> belongs to a nested block
        m = _MD_FM_SCALAR_RE.match(raw.strip())
        if not m:
            continue
        key, value = m.group(1).strip(), m.group(2).strip()
        if not value:
            continue  # a bare `key:` opens a nested block
        out[key] = value.strip('"\'')
    return out


def _parse_frontmatter(fm_lines: "list[str]") -> dict:
    """Parse frontmatter lines into a plain dict.

    Values are passed through ``sanitize_metadata`` by the caller, so nested
    dicts and lists survive while staying bounded and HTML-safe.
    """
    if not fm_lines:
        return {}
    text = "\n".join(fm_lines)
    try:
        import yaml
    except ImportError:
        return _parse_frontmatter_fallback(fm_lines)
    try:
        data = yaml.safe_load(text)
    except Exception:
        # Malformed YAML in one document must not fail the whole extraction.
        return _parse_frontmatter_fallback(fm_lines)
    return data if isinstance(data, dict) else {}


def _nfc(s: str) -> str:
    # Filesystems disagree on Unicode normalization (macOS decomposes, others do
    # not); a link typed in NFC must still find a file listed in NFD.
    return unicodedata.normalize("NFC", s)


def _build_link_index(root: Path) -> "dict[str, list[tuple[int, str, Path]]]":
    """Index every linkable document under *root* by NFC-normalized basename.

    Maps basename -> [(depth, root-relative posix path, absolute path)].
    _SKIP_DIRS and dot-directories are pruned — the same corpus boundary the
    scanner draws, and Obsidian itself does not index dot-folders.
    """
    index: "dict[str, list[tuple[int, str, Path]]]" = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(
            d for d in dirnames if not d.startswith(".") and d not in _SKIP_DIRS
        )
        for fname in filenames:
            if Path(fname).suffix.lower() not in _MD_LINKABLE_EXTS:
                continue
            abs_path = Path(dirpath) / fname
            rel = os.path.relpath(str(abs_path), str(root)).replace("\\", "/")
            index.setdefault(_nfc(fname), []).append(
                (rel.count("/"), _nfc(rel), abs_path)
            )
    return index


def _vault_lookup(target: str, root: Path) -> "Path | None":
    """Resolve *target* against the corpus under *root*, or None.

    A bare name matches by basename; a path-qualified target (``folder/name.md``)
    must match its full segment suffix. Ties break to the shallowest match then
    lexicographically — mirroring Obsidian, where a root-level file wins a bare
    name collision — so resolution is deterministic regardless of walk order.
    """
    root_key = str(root)
    index = _MD_LINK_INDEX_CACHE.get(root_key)
    if index is None:
        try:
            index = _build_link_index(root)
        except OSError:
            index = {}
        _MD_LINK_INDEX_CACHE[root_key] = index
    parts = _nfc(target.replace("\\", "/")).split("/")
    candidates = index.get(parts[-1])
    if not candidates:
        return None
    suffix = "/".join(parts)
    matches = [c for c in candidates if c[1] == suffix or c[1].endswith("/" + suffix)]
    if not matches:
        return None
    return min(matches)[2]


def _resolve_markdown_link(raw: str, source_dir: Path, wikilink: bool = False,
                           scan_root: "Path | None" = None) -> "Path | None":
    """Resolve a link target to the absolute path of a sibling document, or None.

    None means "skip": external URLs (http/https/mailto/protocol-relative/data),
    pure in-page anchors, and links to non-document file types (code and assets
    have their own extractors).

    The anchor (``#section``) and query (``?x=1``) are stripped before resolution
    so ``./repo.md#setup`` reaches the same node as ``./repo.md``. Extension-less
    targets (typical of wikilinks) are treated as sibling ``.md``.

    With ``wikilink=True``, a target whose lexically resolved path does not exist
    is retried as a vault-global lookup across *scan_root* — Obsidian's own
    resolution order. Inline and reference-style links keep pure relative
    semantics: for them a missing relative target is an authoring error, not an
    alternate link convention.
    """
    target = raw.strip()
    if not target:
        return None
    target = target.split("#", 1)[0].split("?", 1)[0].strip()
    if not target:
        return None
    low = target.lower()
    if "://" in target or low.startswith(("mailto:", "tel:", "//", "data:")):
        return None
    suffix = Path(target).suffix.lower()
    if suffix == "":
        target = target + ".md"
        suffix = ".md"
    if suffix not in _MD_LINKABLE_EXTS:
        return None
    candidate = Path(target)
    if not candidate.is_absolute():
        candidate = source_dir / candidate
    resolved = Path(os.path.normpath(str(candidate)))
    if wikilink and not Path(target).is_absolute():
        try:
            missing = not resolved.is_file()
        except OSError:
            missing = False
        if missing and scan_root is not None:
            hit = _vault_lookup(target, scan_root)
            if hit is not None:
                return Path(os.path.normpath(str(hit)))
    return resolved


def extract_markdown(path: Path, scan_root: "Path | None" = None) -> dict:
    """Extract structural nodes and edges from a Markdown file.

    Nodes:
      - the file itself, ``node_kind: "page"``, carrying any YAML frontmatter
      - each heading (# / ## / ...), ``node_kind: "heading"``

    ``node_kind`` exists because ``file_type`` cannot carry the distinction: it is
    a closed enum, and ``"document"`` on both endpoints is load-bearing upstream.
    Without a separate field, headings — usually the majority of nodes in a
    docs-heavy corpus — cannot be filtered out by a consumer.

    Edges:
      - file --contains--> heading
      - parent heading --contains--> child heading (nesting by level)
      - file --references--> linked document, for inline ``[text](./other.md)``,
        reference-style ``[label]: ./other.md`` and ``[[wikilink]]`` links, so a
        hub doc becomes a real hub node instead of an under-connected orphan. The
        target ID is built from the resolved target path with the same recipe as
        that file's own node, so the edge merges into it rather than spawning a
        ghost. External URLs, anchors, images and non-document targets are
        skipped.

    Fenced code blocks are skipped so their contents are not parsed as headings,
    but no node is emitted for them — they were always orphans.

    Leading YAML frontmatter is parsed onto the page node and excluded from
    heading detection (a `#` there is a YAML comment). Links inside it are still
    followed: those are genuine references.

    *scan_root* enables the vault-global wikilink fallback. Upstream reads this
    from a module global; here it is explicit. ``None`` disables the fallback,
    which is upstream's behaviour for a direct call.

    No tree-sitter dependency — pure line-by-line parsing. 0 tokens, no network.
    """
    try:
        source = path.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        return {"nodes": [], "edges": [], "error": str(e)}

    stem = _file_stem(path)
    str_path = str(path)
    nodes: "list[dict]" = []
    edges: "list[dict]" = []
    seen_ids: "set[str]" = set()

    def add_node(nid: str, label: str, line: int, file_type: str = "document",
                 node_kind: str = "heading", extra: "dict | None" = None) -> None:
        if nid not in seen_ids:
            seen_ids.add(nid)
            node = {"id": nid, "label": label, "file_type": file_type,
                    "node_kind": node_kind,
                    "source_file": str_path, "source_location": f"L{line}"}
            if extra:
                node.update(extra)
            nodes.append(node)

    def add_edge(src: str, tgt: str, relation: str, line: int,
                 confidence: str = "EXTRACTED", weight: float = 1.0,
                 target_file: "str | None" = None) -> None:
        edge = {"source": src, "target": tgt, "relation": relation,
                "confidence": confidence, "source_file": str_path,
                "source_location": f"L{line}", "weight": weight}
        if target_file is not None:
            edge["target_file"] = target_file
        edges.append(edge)

    lines = source.splitlines()
    fm_lines, body_start = _split_frontmatter(lines)
    frontmatter = sanitize_metadata(_parse_frontmatter(fm_lines))

    file_nid = _make_id(str(path))
    add_node(file_nid, path.name, 1, node_kind="page",
             extra={"frontmatter": frontmatter} if frontmatter else None)

    source_dir = path.parent
    # Dedup link edges by resolved target so a hub doc linking the same sibling
    # many times yields one edge, not N (keeps weights meaningful).
    linked_targets: "set[str]" = set()

    def add_link(raw: str, line: int, wikilink: bool = False) -> None:
        resolved = _resolve_markdown_link(raw, source_dir, wikilink=wikilink,
                                          scan_root=scan_root)
        if resolved is None:
            return
        # Build the target ID with the SAME recipe as the target file's own node,
        # so both endpoints normalize identically and the edge merges into the
        # existing doc node instead of spawning a ghost.
        tgt_nid = _make_id(str(resolved))
        if tgt_nid == file_nid or tgt_nid in linked_targets:
            return
        linked_targets.add(tgt_nid)
        # Stamp the resolved target file so an incremental consumer can
        # canonicalize this edge's target when the linked doc is not in the
        # batch. Existence-gated: a link to a nonexistent doc must stay dangling.
        target_file = None
        try:
            if resolved.is_file():
                target_file = str(resolved)
        except OSError:
            pass
        add_edge(file_nid, tgt_nid, "references", line, target_file=target_file)

    heading_stack: "list[tuple[int, str]]" = []
    in_code_block = False

    for line_num_0, line_text in enumerate(lines):
        line_num = line_num_0 + 1

        stripped = line_text.strip()
        if stripped.startswith("```"):
            in_code_block = not in_code_block
            continue
        if in_code_block:
            continue

        # Links are scanned on every non-fenced line, including heading lines
        # (the heading branch below `continue`s past this point).
        for m in _MD_INLINE_LINK_RE.finditer(line_text):
            add_link(m.group(1), line_num)
        for m in _MD_WIKILINK_RE.finditer(line_text):
            add_link(m.group(1), line_num, wikilink=True)
        ref_def = _MD_REF_DEF_RE.match(line_text)
        if ref_def:
            add_link(ref_def.group(1), line_num)

        # Inside frontmatter a leading `#` is a YAML comment, not an H1. Links
        # above are still scanned there on purpose; only headings are suppressed.
        if line_num_0 < body_start:
            continue

        heading_match = re.match(r'^(#{1,6})\s+(.+)', line_text)
        if heading_match:
            level = len(heading_match.group(1))
            title = heading_match.group(2).strip()
            h_nid = _make_id(stem, title)
            # Avoid duplicate heading IDs by appending the line number.
            if h_nid in seen_ids:
                h_nid = _make_id(stem, title, str(line_num))
            add_node(h_nid, title, line_num)

            while heading_stack and heading_stack[-1][0] >= level:
                heading_stack.pop()

            parent = heading_stack[-1][1] if heading_stack else file_nid
            add_edge(parent, h_nid, "contains", line_num)

            heading_stack.append((level, h_nid))
            continue

    return {"nodes": nodes, "edges": edges, "input_tokens": 0, "output_tokens": 0}
