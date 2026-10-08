#!/usr/bin/env python3
"""Extracts one version's section from CHANGELOG.md and converts it to a
small HTML fragment for Sparkle's appcast <description> — shown right in
the native update dialog the user already sees when Sparkle finds a new
version, so "what changed" doesn't need a separate interruption.

Deliberately a tiny hand-rolled converter, not a markdown library
dependency: the only syntax CHANGELOG.md ever actually uses is
"### heading" and "- bullet" lines, both trivial to match line by line.
"""
import html
import re
import sys


def extract_section(changelog_text: str, version: str) -> str:
    pattern = re.compile(
        rf"^## \[?{re.escape(version)}\]?.*?$\n(.*?)(?=^## |\Z)",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(changelog_text)
    if not match:
        raise SystemExit(f"No CHANGELOG.md section found for version {version}")
    return match.group(1).strip("\n")


def inline_format(escaped_text: str) -> str:
    """Applied after html.escape(), so **/`/[]() below are always literal
    characters, never something an attacker-controlled string could smuggle
    HTML through — CHANGELOG.md is a file we author ourselves, but this
    keeps the conversion correct regardless. Found missing (rendered as
    literal "[text](url)") in the v1.5.0 release notes right before this
    script produced its appcast — a real, visible gap, not hypothetical."""
    text = re.sub(r"\[(.+?)\]\((https?://[^\s)]+)\)", r'<a href="\2">\1</a>', escaped_text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
    return text


def to_html(section: str) -> str:
    """Accumulates each list item/paragraph's full RAW text across all of
    its wrapped continuation lines first, and only escapes+formats it once
    that's complete — not line by line. A `**bold**` span that wraps across
    a continuation line (a real, common shape in this CHANGELOG's longer
    bullets) has its opening and closing markers on two different physical
    lines; formatting each line in isolation, as an earlier version of this
    function did, meant `inline_format` never saw both markers in the same
    call and left the asterisks in literally — confirmed by regenerating a
    real release's appcast section and finding several bullets that
    happened to wrap exactly where a `**...**` span crossed the line break."""
    lines = section.splitlines()
    html_lines: list[str] = []
    in_list = False
    current_tag: str | None = None
    current_text = ""

    def flush() -> None:
        nonlocal current_tag, current_text
        if current_tag is not None:
            html_lines.append(f"<{current_tag}>{inline_format(html.escape(current_text))}</{current_tag}>")
        current_tag = None
        current_text = ""

    for line in lines:
        stripped = line.strip()
        if not stripped:
            flush()
            continue
        if stripped.startswith("### "):
            flush()
            if in_list:
                html_lines.append("</ul>")
                in_list = False
            html_lines.append(f"<h4>{inline_format(html.escape(stripped[4:]))}</h4>")
        elif stripped.startswith("- "):
            flush()
            if not in_list:
                html_lines.append("<ul>")
                in_list = True
            current_tag = "li"
            current_text = stripped[2:]
        elif current_tag is not None:
            current_text += " " + stripped
        else:
            flush()
            if in_list:
                html_lines.append("</ul>")
                in_list = False
            current_tag = "p"
            current_text = stripped

    flush()
    if in_list:
        html_lines.append("</ul>")
    return "\n".join(html_lines)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <CHANGELOG.md path> <version>", file=sys.stderr)
        sys.exit(1)
    changelog_path, version = sys.argv[1], sys.argv[2]
    with open(changelog_path, encoding="utf-8") as f:
        text = f.read()
    print(to_html(extract_section(text, version)))
