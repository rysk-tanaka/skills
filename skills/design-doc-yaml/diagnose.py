#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml"]
# ///
"""
diagnose.py - Turn a local design YAML scaffold into a Markdown + Mermaid
self-review report.

This is a DETERMINISTIC transform. It does not interpret meaning.

It RENDERS the structure you authored:

  - relations graph (Mermaid)           -> see the shape at a glance
  - importance-sorted concept list      -> bloat (low-importance noise) sinks down

It FLAGS structural defects to fix (delete the problem by editing the YAML):

  - input format problems               -> non-mapping list elements, wrong/missing version
  - concepts with no id                 -> unreferenceable; would vanish from analysis
  - orphan concepts                     -> something you forgot to wire up
  - dangling relation refs              -> a relation points at a missing id
  - incomplete relations                -> a relation is missing its `from` or `to`
  - duplicate concept ids               -> a later entry silently overwrites an earlier one
  - risks without a disposition         -> a risk you noted but never resolved

It also SURFACES blocking open questions. These are NOT auto-clearable defects:
a blocking question is an unresolved thing that gates the design, deliberately
foregrounded. Resolve it or consciously keep it -- do not "clear" it by deletion.

Run it during the review loop, read the report in your Markdown previewer
(Obsidian / Zed render Mermaid), fix the YAML, re-run. The report is a
throwaway review aid, never the deliverable.

Usage:
    uv run diagnose.py path/to/design.yaml [-o report.md]

Exit code is 0 even when defects are found (defects are reported, not fatal).
Use --strict to exit non-zero when any defect OR a blocking question remains
(handy for a pre-commit style gate on your own scaffold). Input/IO errors exit 2.
"""

import argparse
import re
import sys
from collections import Counter
from collections.abc import Hashable

EXPECTED_VERSION = "design/v1"

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "PyYAML is required. Install it with:\n"
        "    pip install pyyaml\n"
    )
    sys.exit(2)


# --- helpers ---------------------------------------------------------------

def _as_list(node, key):
    v = (node or {}).get(key)
    if v is None:
        return []
    if not isinstance(v, list):
        return [v]
    return v


def _esc(text):
    """Escape for a Mermaid node/edge label.

    A literal '|' would close an edge-label fence (``-->|label|``) early and
    break the whole graph, so it is neutralized along with quotes/newlines.
    """
    return (
        str(text)
        .replace('"', "'")
        .replace("|", "/")
        .replace("\n", " ")
        .strip()
    )


def _md_cell(text):
    return str(text).replace("|", "\\|").replace("\n", " ").strip()


def _safe_node_id(raw, mapping):
    """Map an arbitrary concept id to a Mermaid-safe node id (alnum/_ only).

    Mermaid node ids cannot contain '-', '.', spaces, etc.; emitting a raw id
    like `rate-limit` or `api.gateway` produces a syntax error and the whole
    graph fails to render. We map each original id to a sanitized node id once,
    keep the mapping stable within a report, and avoid collisions. The original
    id still surfaces as the human-readable node label.
    """
    if raw in mapping:
        return mapping[raw]
    base = re.sub(r"[^0-9A-Za-z_]", "_", str(raw))
    if not base or not (base[0].isalpha() or base[0] == "_"):
        base = "n_" + base
    candidate = base
    existing = set(mapping.values())
    i = 1
    while candidate in existing:
        i += 1
        candidate = f"{base}_{i}"
    mapping[raw] = candidate
    return candidate


IMPORTANCE_ORDER = {"high": 0, "medium": 1, "med": 1, "low": 2}


# --- report sections -------------------------------------------------------

def section_overview(doc):
    target = doc.get("target") or {}
    if not isinstance(target, dict):
        target = {}
    title = target.get("title", "(untitled)")
    ttype = target.get("type", "design")
    lines = [f"# 診断レポート: {title}", "", f"_対象: {ttype}_  ·  _このファイルは使い捨てのレビュー補助です_", ""]
    return "\n".join(lines)


def section_graph(concepts, relations):
    """Mermaid graph of relations between concepts."""
    label_of = {c.get("id"): c.get("label", c.get("id")) for c in concepts}
    node_ids = {}  # original concept id -> Mermaid-safe node id
    lines = ["## 関係グラフ", "", "```mermaid", "graph LR"]
    # declare nodes (so isolated concepts still show up)
    for c in concepts:
        cid = c.get("id")
        if cid is None:
            continue
        imp = str(c.get("importance") or "").lower()
        label = _esc(label_of.get(cid, cid))
        node = _safe_node_id(cid, node_ids)
        if imp == "high":
            lines.append(f'    {node}["{label}"]:::high')
        else:
            lines.append(f'    {node}["{label}"]')
    for r in relations:
        frm, to = r.get("from"), r.get("to")
        if frm is None or to is None:
            continue
        frm_node = _safe_node_id(frm, node_ids)
        to_node = _safe_node_id(to, node_ids)
        rlabel = r.get("label") or r.get("type") or ""
        if rlabel:
            lines.append(f'    {frm_node} -->|{_esc(rlabel)}| {to_node}')
        else:
            lines.append(f"    {frm_node} --> {to_node}")
    lines.append("    classDef high stroke-width:3px;")
    lines.append("```")
    lines.append("")
    return "\n".join(lines)


def section_defects(concepts, relations, risks, open_qs, format_warnings):
    # only ids that are actually usable; missing/empty ones are reported separately
    # (concepts_no_id below) instead of polluting orphan/dangling/duplicate output.
    ids = {c.get("id") for c in concepts if str(c.get("id") or "").strip()}
    referenced = set()
    dangling = []
    incomplete_rels = []
    for r in relations:
        for end in ("from", "to"):
            ref = r.get(end)
            if ref is None:
                # `from`/`to` missing entirely: the relation appears in neither
                # the graph nor dangling output, so flag it instead of skipping.
                incomplete_rels.append((r, end))
                continue
            referenced.add(ref)
            if ref not in ids:
                dangling.append((r.get("from"), r.get("to"), end, ref))

    orphans = sorted(ids - referenced)
    risks_no_disp = [
        rk for rk in risks
        if not str(rk.get("disposition") or "").strip()
    ]
    blocking = [q for q in open_qs if q.get("blocking")]

    # duplicate concept ids: same authoring-mistake class as orphans/dangling.
    # (ids were coerced to a hashable form upstream in build_report.)
    id_counts = Counter(
        c.get("id") for c in concepts if str(c.get("id") or "").strip()
    )
    dup_ids = [i for i, n in id_counts.items() if n > 1]

    # concepts with no usable id: schema requires id (必須/一意), and without one
    # the concept is unreferenceable and silently drops out of graph/orphan/dangling
    # analysis -- so flag it explicitly rather than let it vanish.
    concepts_no_id = [c for c in concepts if not str(c.get("id") or "").strip()]

    lines = ["## 要確認", ""]
    any_defect = False

    # Input-format problems (non-mapping list elements, wrong/missing version)
    # collected upstream. These must reach the report and --strict, otherwise a
    # malformed scaffold renders as "no defects" -- the opposite of this tool's job.
    if format_warnings:
        any_defect = True
        lines.append("**入力フォーマットの問題** — スキーマに沿わない箇所です（スキップ済み・結果が不正確になりえます）:")
        for w in format_warnings:
            lines.append(f"- {_md_cell(w)}")
        lines.append("")
    if concepts_no_id:
        any_defect = True
        lines.append("**id 未設定の concept** — id が無い/空で、参照も検出もできません:")
        for c in concepts_no_id:
            hint = _md_cell(c.get("label") or c.get("summary") or "(label なし)")
            lines.append(f"- {hint}")
        lines.append("")
    if dup_ids:
        any_defect = True
        lines.append("**重複した concept id** — 同じ id が複数の concept に使われています（後勝ちで無言マージされます）:")
        for d in dup_ids:
            lines.append(f"- `{d}`")
        lines.append("")
    if dangling:
        any_defect = True
        lines.append("**参照切れ relations** — 存在しない concept id を指しています:")
        for frm, to, end, ref in dangling:
            lines.append(f"- `{frm} -> {to}` の `{end}: {ref}` は未定義")
        lines.append("")
    if incomplete_rels:
        any_defect = True
        lines.append("**不完全な relation** — `from` または `to` が未設定です:")
        for r, end in incomplete_rels:
            other = "to" if end == "from" else "from"
            lines.append(f"- `{end}` 欠落（`{other}: {_md_cell(r.get(other, '?'))}`）")
        lines.append("")
    if orphans:
        any_defect = True
        lines.append("**孤立 concept** — どの relation にも現れません（繋ぎ忘れの可能性）:")
        for o in orphans:
            lines.append(f"- `{o}`")
        lines.append("")
    if risks_no_disp:
        any_defect = True
        lines.append("**未処理の risk** — `disposition` が空です（許容/対応を決めていない）:")
        for rk in risks_no_disp:
            lines.append(f"- {_md_cell(rk.get('label', '(no label)'))}")
        lines.append("")
    if blocking:
        # Separate from the structural defects above: a blocking question is
        # deliberately foregrounded, not a defect to delete (see SKILL.md).
        if any_defect:
            lines.append("---")
            lines.append("")
        any_defect = True
        lines.append("**ブロッキングな open question** — 設計を止めうる未解決事項（構造欠陥ではありません。解決するか、残すと決めてください）:")
        for q in blocking:
            lines.append(f"- {_md_cell(q.get('question', '(no text)'))}")
        lines.append("")

    if not any_defect:
        lines.append("構造的な欠陥は検出されませんでした。")
        lines.append("")

    return "\n".join(lines), any_defect


def section_concepts_table(concepts):
    def sort_key(c):
        imp = str(c.get("importance") or "").lower()
        return (IMPORTANCE_ORDER.get(imp, 1), str(c.get("id")))

    lines = ["## concept 一覧（重要度順）", "",
             "| importance | id | label | difficulty |",
             "| --- | --- | --- | --- |"]
    for c in sorted(concepts, key=sort_key):
        lines.append(
            f"| {_md_cell(c.get('importance', '-'))} "
            f"| `{_md_cell(c.get('id', '-'))}` "
            f"| {_md_cell(c.get('label', '-'))} "
            f"| {_md_cell(c.get('difficulty', '-'))} |"
        )
    lines.append("")
    return "\n".join(lines)


def section_risks_table(risks):
    if not risks:
        return ""
    lines = ["## risk 一覧", "",
             "| severity | label | disposition |",
             "| --- | --- | --- |"]
    # severity shares the high/medium/low ranking with importance.
    for rk in sorted(risks, key=lambda r: IMPORTANCE_ORDER.get(str(r.get("severity") or "").lower(), 1)):
        lines.append(
            f"| {_md_cell(rk.get('severity', '-'))} "
            f"| {_md_cell(rk.get('label', '-'))} "
            f"| {_md_cell(rk.get('disposition') or '— (未決)')} |"
        )
    lines.append("")
    return "\n".join(lines)


def section_open_questions(open_qs):
    if not open_qs:
        return ""
    lines = ["## open questions", ""]
    for q in open_qs:
        mark = "🚧 " if q.get("blocking") else ""
        lines.append(f"- {mark}{_md_cell(q.get('question', '(no text)'))}")
    lines.append("")
    return "\n".join(lines)


def section_synthesis(syn):
    if not syn:
        return ""
    lines = ["## synthesis（清書への舵取り）", ""]
    if syn.get("lead_with"):
        lines.append(f"- **先頭に置く**: {_md_cell(syn['lead_with'])}")
    for f in _as_list(syn, "foreground"):
        lines.append(f"- **前面に出す**: {_md_cell(f)}")
    for d in _as_list(syn, "defer_detail"):
        lines.append(f"- **詳細は後回し**: {_md_cell(d)}")
    for t in _as_list(syn, "terse"):
        lines.append(f"- **簡潔に**: {_md_cell(t)}")
    lines.append("")
    return "\n".join(lines)


# --- main ------------------------------------------------------------------

def _mappings(items, kind, warnings):
    """Keep only mapping elements; record + warn on anything else.

    YAML can parse fine yet hand us a list whose elements are scalars (e.g.
    ``concepts: [- rate-limit]``). Every consumer calls ``.get`` on the element,
    so a non-mapping would crash the very tool meant to flag structural defects.
    We collect the problem into ``warnings`` (so it reaches the report and
    --strict) and skip it rather than blow up with a traceback. ``warnings`` is
    passed in by the caller -- no module global -- so each run starts clean.
    """
    out = []
    for idx, item in enumerate(items):
        if isinstance(item, dict):
            out.append(item)
        else:
            msg = f"{kind}[{idx}] が mapping ではありません（{type(item).__name__}）"
            warnings.append(msg)
            sys.stderr.write(f"warning: {msg}; skipped\n")
    return out


def build_report(doc):
    # Input-format problems collected here and threaded into section_defects so
    # they surface in the report and gate --strict (not just stderr).
    format_warnings = []

    # concepts is schema-required: without it the report would render an empty
    # structure and report "no defects", giving false reassurance.
    raw_concepts = doc.get("concepts")
    if raw_concepts is None or (isinstance(raw_concepts, list) and not raw_concepts):
        format_warnings.append("`concepts` が未設定/空です（スキーマ上必須）")

    version = doc.get("version")
    if version is None:
        format_warnings.append(
            f"`version` が未設定です（`{EXPECTED_VERSION}` を期待）"
        )
    elif str(version) != EXPECTED_VERSION:
        format_warnings.append(
            f"`version: {_md_cell(version)}` は未対応です"
            f"（`{EXPECTED_VERSION}` を期待・別スキーマ/誤記の可能性）"
        )

    concepts = _mappings(_as_list(doc, "concepts"), "concepts", format_warnings)
    relations = _mappings(_as_list(doc, "relations"), "relations", format_warnings)
    risks = _mappings(_as_list(doc, "risks"), "risks", format_warnings)
    open_qs = _mappings(_as_list(doc, "open_questions"), "open_questions", format_warnings)
    synthesis = doc.get("synthesis") or {}
    if not isinstance(synthesis, dict):
        msg = f"`synthesis` が mapping ではありません（{type(synthesis).__name__}）"
        format_warnings.append(msg)
        sys.stderr.write(f"warning: {msg}; ignored\n")
        synthesis = {}

    # Coerce non-hashable ids (a YAML typo like `id: [a, b]`) to strings, here at
    # the boundary, so every downstream set/dict keyed on an id stays crash-proof
    # on the malformed scaffold this tool exists to flag.
    for c in concepts:
        if not isinstance(c.get("id"), Hashable):
            c["id"] = str(c.get("id"))
    for r in relations:
        for end in ("from", "to"):
            if not isinstance(r.get(end), Hashable):
                r[end] = str(r.get(end))

    parts = [section_overview(doc)]
    defects_md, any_defect = section_defects(
        concepts, relations, risks, open_qs, format_warnings
    )
    parts.append(defects_md)
    if concepts:
        parts.append(section_graph(concepts, relations))
        parts.append(section_concepts_table(concepts))
    parts.append(section_risks_table(risks))
    parts.append(section_open_questions(open_qs))
    parts.append(section_synthesis(synthesis))
    return "\n".join(p for p in parts if p), any_defect


def main(argv=None):
    ap = argparse.ArgumentParser(description="Diagnose a design YAML scaffold.")
    ap.add_argument("yaml_path", help="path to the design YAML")
    ap.add_argument("-o", "--out", help="write report here (default: stdout)")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 if any structural defect or blocking question remains "
                         "(input/IO errors always exit 2)")
    args = ap.parse_args(argv)

    try:
        with open(args.yaml_path, "r", encoding="utf-8") as f:
            doc = yaml.safe_load(f) or {}
    except OSError as e:
        # FileNotFoundError, IsADirectoryError, PermissionError, ... all land here
        sys.stderr.write(f"cannot read {args.yaml_path}: {e}\n")
        return 2
    except yaml.YAMLError as e:
        sys.stderr.write(f"YAML parse error: {e}\n")
        return 2

    if not isinstance(doc, dict):
        sys.stderr.write("top-level YAML must be a mapping\n")
        return 2

    report, any_defect = build_report(doc)

    if args.out:
        try:
            with open(args.out, "w", encoding="utf-8") as f:
                f.write(report + "\n")
        except OSError as e:
            sys.stderr.write(f"cannot write {args.out}: {e}\n")
            return 2
        sys.stderr.write(f"wrote {args.out}\n")
    else:
        sys.stdout.write(report + "\n")

    if args.strict and any_defect:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
