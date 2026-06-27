#!/usr/bin/env python3
"""
Prose / comment vocabulary scanner.

Scans code comments and documentation prose for vocabulary patterns declared
in a rules dictionary (rules.toml), and emits findings as JSON on stdout.

This script only DETECTS. The actual rewriting is performed by the agent
following SKILL.md, which can judge contextual / density cases.

Usage:
    uv run scan.py <path> [<path> ...]
    uv run scan.py src/ docs/ --profile docs
    uv run scan.py README.md --rules ./rules.toml
"""

# /// script
# requires-python = ">=3.12"
# dependencies = ["pygments", "typer"]
# ///

import json
import re
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

import typer
from pygments.lexers import guess_lexer_for_filename
from pygments.token import Comment, String
from pygments.util import ClassNotFound

# =============================================================================
# Constants
# =============================================================================

# Files treated as pure prose (whole content scanned, code fences stripped).
PROSE_EXTS = {".md", ".markdown", ".mdx", ".txt", ".rst", ".adoc"}

# Extensions worth lexing for comments. Anything pygments can guess is fine,
# but we skip obvious binary / lock / data files.
SKIP_EXTS = {
    ".lock", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".pdf", ".zip",
    ".woff", ".woff2", ".ttf", ".ico", ".min.js", ".min.css",
}
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", ".tmp"}

# Accepted --profile values (also constrains rules.toml's default_profile).
VALID_PROFILES = {"technical", "docs", "strict"}

# Skip text files larger than this to avoid loading huge logs / generated files
# into memory (binaries are already excluded via SKIP_EXTS).
MAX_FILE_BYTES = 2 * 1024 * 1024

EN_WORD = re.compile(r"[A-Za-z][A-Za-z'-]*")


# =============================================================================
# Data structures
# =============================================================================


@dataclass
class Finding:
    path: str
    line: int
    lang: Literal["en", "ja"]
    tier: Literal["always", "contextual", "pattern"]
    matched: str       # the actual matched surface text
    base: str          # the rule key
    suggest: list[str]
    snippet: str
    note: str = ""
    allowed_by_profile: bool = False  # contextual only; ignored for other tiers

    def as_dict(self) -> dict[str, Any]:
        d = {
            "path": self.path,
            "line": self.line,
            "lang": self.lang,
            "tier": self.tier,
            "matched": self.matched,
            "base": self.base,
            "suggest": self.suggest,
            "snippet": self.snippet,
        }
        if self.note:
            d["note"] = self.note
        if self.tier == "contextual":
            d["allowed_by_profile"] = self.allowed_by_profile
        return d


@dataclass
class ProseLine:
    line: int
    text: str


@dataclass
class Rules:
    default_profile: str
    en_always: dict[str, list[str]]
    en_contextual: dict[str, dict[str, Any]]
    en_density_threshold: float
    en_density_words: list[str]
    ja_always: dict[str, list[str]]
    ja_contextual: dict[str, dict[str, Any]]
    ja_density_words: list[str]
    en_patterns: dict[str, re.Pattern[str]] = field(default_factory=dict)   # base -> compiled regex
    en_structural: dict[str, dict[str, Any]] = field(default_factory=dict)  # id -> {re, suggest, note}
    ja_structural: dict[str, dict[str, Any]] = field(default_factory=dict)  # id -> {re, suggest, note}


# =============================================================================
# Rule loading
# =============================================================================


def expand_en_variants(base: str) -> re.Pattern[str]:
    """Build a case-insensitive regex matching a word and its common variants.

    Phrases (containing spaces / hyphens) match literally with flexible
    whitespace. Single words match base + inflections (-s/-es/-ed/-ing/-ly),
    with light rules for words ending in 'e' (-ed/-ing) or 'y' (-ies).
    """
    if " " in base or "-" in base:
        parts = re.split(r"[ \-]+", base.strip())
        joined = r"[ \-]+".join(re.escape(p) for p in parts)
        return re.compile(rf"\b{joined}\b", re.IGNORECASE)

    # Inflect per ending so we only generate real forms (no "leveragees" / "embarkes").
    # "ly" is kept for adjective->adverb (seamless -> seamlessly).
    forms = {base, base + "ly"}
    if base.endswith("e"):
        forms |= {base + "s", base[:-1] + "ed", base[:-1] + "ing"}
    elif base.endswith("y") and len(base) > 1 and base[-2] not in "aeiou":
        forms |= {base[:-1] + "ies", base[:-1] + "ied", base + "ing"}
    else:
        forms |= {base + "s", base + "ed", base + "ing"}
        if base.endswith(("s", "x", "z", "ch", "sh")):
            forms.add(base + "es")
    alts = "|".join(sorted((re.escape(f) for f in forms), key=len, reverse=True))
    return re.compile(rf"\b(?:{alts})\b", re.IGNORECASE)


def load_rules(rules_path: Path) -> Rules:
    with rules_path.open("rb") as fh:
        data = tomllib.load(fh)

    en = data.get("en", {})
    ja = data.get("ja", {})
    en_always = en.get("always", {})
    en_contextual = en.get("contextual", {})
    en_density = en.get("density", {})
    ja_always = ja.get("always", {})
    ja_contextual = ja.get("contextual", {})
    ja_density = ja.get("density", {})

    rules = Rules(
        default_profile=data.get("meta", {}).get("default_profile", "technical"),
        en_always=en_always,
        en_contextual=en_contextual,
        en_density_threshold=float(en_density.get("threshold", 0.03)),
        en_density_words=list(en_density.get("words", [])),
        ja_always=ja_always,
        ja_contextual=ja_contextual,
        ja_density_words=list(ja_density.get("words", [])),
    )

    # Pre-compile English patterns (always + contextual + density words).
    bases = set(en_always) | set(en_contextual) | set(rules.en_density_words)
    rules.en_patterns = {b: expand_en_variants(b) for b in bases}

    # Compile structural (regex) patterns.
    def compile_structural(section: dict[str, Any]) -> dict[str, dict[str, Any]]:
        out: dict[str, dict[str, Any]] = {}
        for pid, spec in section.items():
            try:
                compiled = re.compile(spec["regex"])
            except KeyError:
                raise KeyError(f"pattern '{pid}' is missing required 'regex' key") from None
            except re.error as err:
                raise re.error(f"pattern '{pid}' has invalid regex: {err}") from err
            out[pid] = {
                "re": compiled,
                "suggest": list(spec.get("suggest", [])),
                "note": spec.get("note", ""),
            }
        return out

    rules.en_structural = compile_structural(en.get("pattern", {}))
    rules.ja_structural = compile_structural(ja.get("pattern", {}))
    return rules


# =============================================================================
# Prose extraction
# =============================================================================


def _blank_keep_newlines(match: re.Match[str]) -> str:
    """Replace a span with spaces but keep its newlines, so line numbers and
    paragraph breaks downstream stay aligned with the original text."""
    return re.sub(r"[^\n]", " ", match.group(0))


def strip_md_code(text: str) -> str:
    """Blank out fenced and inline code so we don't flag code identifiers.

    A fence (``` or ~~~, 3+ markers) is closed only by the same marker run, so a
    ``` block containing ~~~ is not cut short; an unclosed fence runs to EOF.
    Newlines are preserved so line numbers stay aligned.
    """
    fence = re.compile(r"(?P<fence>`{3,}|~{3,}).*?(?:(?P=fence)|\Z)", re.DOTALL)
    text = fence.sub(_blank_keep_newlines, text)
    text = re.sub(r"`[^`\n]*`", " ", text)
    return text


def extract_prose(path: Path) -> tuple[list[ProseLine], str | None]:
    """Return (prose_lines, skip_reason). skip_reason set => file skipped."""
    suffix = path.suffix.lower()
    # Match by filename, not Path.suffix: suffix returns only the last
    # component, so multi-part entries like ".min.js" would never match.
    skip_ext = next((e for e in SKIP_EXTS if path.name.lower().endswith(e)), None)
    if skip_ext:
        return [], f"skipped extension {skip_ext}"

    try:
        if path.stat().st_size > MAX_FILE_BYTES:
            return [], f"skipped: too large (> {MAX_FILE_BYTES // 1024} KB)"
        raw = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return [], "undecodable as UTF-8 (re-save as UTF-8 to scan)"
    except OSError as err:
        return [], f"unreadable: {err.strerror or err}"

    if suffix in PROSE_EXTS:
        cleaned = strip_md_code(raw) if suffix in {".md", ".markdown", ".mdx"} else raw
        return [ProseLine(i, t) for i, t in enumerate(cleaned.splitlines(), 1) if t.strip()], None

    # Code file: extract comment + docstring tokens via pygments.
    try:
        lexer = guess_lexer_for_filename(path.name, raw)
    except ClassNotFound:
        return [], "no lexer (not prose, not lexable)"

    lines: dict[int, list[str]] = {}
    current = 1
    for ttype, value in lexer.get_tokens(raw):
        if (ttype in Comment or ttype in String.Doc) and value.strip():
            seg_line = current
            for j, piece in enumerate(value.split("\n")):
                if piece.strip():
                    lines.setdefault(seg_line + j, []).append(piece)
        current += value.count("\n")

    return [ProseLine(n, " ".join(parts)) for n, parts in sorted(lines.items())], None


# =============================================================================
# Matching
# =============================================================================


def ja_needle(key: str) -> str:
    return key[1:] if key.startswith("\u301c") or key.startswith("~") else key


def scan_prose(
    path: str,
    prose: list[ProseLine],
    rules: Rules,
    profile: str,
) -> tuple[list[Finding], list[dict]]:
    findings: list[Finding] = []

    # --- per-line lexical matches (always + contextual) ---
    for pl in prose:
        text = pl.text

        # English always
        for base, suggest in rules.en_always.items():
            for m in rules.en_patterns[base].finditer(text):
                findings.append(Finding(
                    path, pl.line, "en", "always", m.group(0), base,
                    list(suggest), text.strip()))

        # English contextual
        for base, spec in rules.en_contextual.items():
            allow_in = spec.get("allow_in", [])
            allowed = profile in allow_in
            for m in rules.en_patterns[base].finditer(text):
                findings.append(Finding(
                    path, pl.line, "en", "contextual", m.group(0), base,
                    list(spec.get("suggest", [])), text.strip(),
                    note=spec.get("note", ""), allowed_by_profile=allowed))

        # Japanese always
        for key, suggest in rules.ja_always.items():
            needle = ja_needle(key)
            if needle and needle in text:
                findings.append(Finding(
                    path, pl.line, "ja", "always", needle, key,
                    list(suggest), text.strip()))

        # Japanese contextual
        for key, spec in rules.ja_contextual.items():
            needle = ja_needle(key)
            allow_in = spec.get("allow_in", [])
            allowed = profile in allow_in
            if needle and needle in text:
                findings.append(Finding(
                    path, pl.line, "ja", "contextual", needle, key,
                    list(spec.get("suggest", [])), text.strip(),
                    note=spec.get("note", ""), allowed_by_profile=allowed))

        # Structural patterns (regex). Detect-only; the agent restructures.
        for lang, section in (("en", rules.en_structural), ("ja", rules.ja_structural)):
            for pid, spec in section.items():
                for m in spec["re"].finditer(text):
                    findings.append(Finding(
                        path, pl.line, lang, "pattern", m.group(0), pid,
                        list(spec["suggest"]), text.strip(), note=spec["note"]))

    # --- density (file-level ratio + paragraph co-occurrence) ---
    density_reports: list[dict] = []
    # Rebuild text at original line positions so blank-line paragraph breaks
    # survive. ProseLine drops blank lines, so a plain join would collapse the
    # whole file into one paragraph and make co-occurrence checks file-wide.
    if prose:
        by_line = {pl.line: pl.text for pl in prose}
        full = "\n".join(by_line.get(n, "") for n in range(1, max(by_line) + 1))
    else:
        full = ""

    # English density
    en_total = sum(1 for _ in EN_WORD.finditer(full))
    if en_total and rules.en_density_words:
        counts: dict[str, int] = {}
        for w in rules.en_density_words:
            c = sum(1 for _ in rules.en_patterns[w].finditer(full))
            if c:
                counts[w] = c
        hit = sum(counts.values())
        ratio = hit / en_total
        if counts and ratio >= rules.en_density_threshold:
            density_reports.append({
                "path": path, "lang": "en", "ratio": round(ratio, 4),
                "threshold": rules.en_density_threshold, "words": counts})

    # Paragraph co-occurrence (>=2 distinct density words together) for en & ja
    for lang, words, patterns in (
        ("en", rules.en_density_words, rules.en_patterns),
        ("ja", rules.ja_density_words, None),
    ):
        if not words:
            continue
        for para in re.split(r"\n\s*\n", full):
            if not para.strip():
                continue
            present = []
            for w in words:
                if lang == "en":
                    if patterns[w].search(para):
                        present.append(w)
                elif w in para:
                    present.append(w)
            if len(present) >= 2:
                density_reports.append({
                    "path": path, "lang": lang, "cooccurrence": present,
                    "snippet": para.strip()[:120]})

    return findings, density_reports


# =============================================================================
# File discovery
# =============================================================================


def discover(paths: list[Path]) -> tuple[list[Path], list[Path]]:
    """Return (files, missing). Prunes SKIP_DIRS during the walk so we never
    descend into .git / node_modules / etc. Nonexistent inputs go into
    `missing` so the caller can surface a typo instead of scanning nothing."""
    out: list[Path] = []
    missing: list[Path] = []
    for p in paths:
        if p.is_dir():
            found: list[Path] = []
            for root, dirs, files in p.walk(top_down=True):
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
                found.extend(root / name for name in files)
            out.extend(sorted(found))
        elif p.is_file():
            out.append(p)
        else:
            missing.append(p)

    # Dedup by canonical path so overlapping inputs (e.g. `.` and `docs/`) don't
    # scan the same file twice and inflate the counts. Keep the first-seen path
    # for display so output stays relative to what the user passed.
    seen: set[Path] = set()
    deduped: list[Path] = []
    for f in out:
        key = f.resolve()
        if key not in seen:
            seen.add(key)
            deduped.append(f)
    return deduped, missing


# =============================================================================
# CLI
# =============================================================================

app = typer.Typer(add_completion=False)


@app.command()
def main(
    paths: list[Path] = typer.Argument(..., help="Files or directories to scan"),
    rules_path: Path = typer.Option(
        Path(__file__).parent / "rules.toml", "--rules", help="Rule dictionary path"),
    profile: str = typer.Option(
        "", "--profile", "-p", help="technical | docs | strict (default from rules)"),
) -> None:
    """Scan files for prose vocabulary patterns and emit JSON findings."""
    try:
        rules = load_rules(rules_path)
    except (OSError, tomllib.TOMLDecodeError, re.error, KeyError,
            ValueError, TypeError, AttributeError) as err:
        print(f"Error: failed to load rules ({rules_path}): {err}", file=sys.stderr)
        raise typer.Exit(1) from None

    active_profile = profile or rules.default_profile
    if active_profile not in VALID_PROFILES:
        print(
            f"Error: invalid profile '{active_profile}'. "
            f"Use one of: {', '.join(sorted(VALID_PROFILES))}",
            file=sys.stderr)
        raise typer.Exit(1)

    files, missing = discover(paths)

    all_findings: list[Finding] = []
    all_density: list[dict] = []
    skipped: list[dict] = [{"path": str(p), "reason": "path not found"} for p in missing]
    scanned = 0

    for fp in files:
        prose, reason = extract_prose(fp)
        if reason:
            skipped.append({"path": str(fp), "reason": reason})
            continue
        if not prose:
            continue
        scanned += 1
        f, d = scan_prose(str(fp), prose, rules, active_profile)
        all_findings.extend(f)
        all_density.extend(d)

    result = {
        "profile": active_profile,
        "rules_path": str(rules_path),
        "files_scanned": scanned,
        "files_skipped": skipped,
        "summary": {
            "total": len(all_findings),
            "always": sum(1 for f in all_findings if f.tier == "always"),
            "pattern": sum(1 for f in all_findings if f.tier == "pattern"),
            "contextual_flagged": sum(
                1 for f in all_findings
                if f.tier == "contextual" and not f.allowed_by_profile),
            "contextual_allowed": sum(
                1 for f in all_findings
                if f.tier == "contextual" and f.allowed_by_profile),
            "density_reports": len(all_density),
        },
        "findings": [f.as_dict() for f in all_findings],
        "density": all_density,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    app()
