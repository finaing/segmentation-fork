#!/usr/bin/env python3
"""Count the sentences and signs in each project's automatically segmented EAFs.

Reads <share_path>/pose/auto_segmented/*.eaf (written by project_to_segments.sh)
for each project in the projects CSV and prints, per project, the number of EAF
files and the number of annotations on their SENTENCE and SIGN tiers, plus a
total row. Only needs the standard library, so it runs without the conda env.

Usage:
    python3 count_segments.py [--csv PATH] [--share-prefix PATH] [--out CSV] [PROJECT ...]
"""
import argparse
import csv
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

TIERS = ("SENTENCE", "SIGN")


def count_eaf(path: Path) -> dict[str, int]:
    """Number of annotations per tier in TIERS (0 for a missing tier)."""
    root = ET.parse(path).getroot()
    counts = dict.fromkeys(TIERS, 0)
    for tier in root.iter("TIER"):
        tier_id = tier.get("TIER_ID")
        if tier_id in counts:
            counts[tier_id] += len(tier.findall("ANNOTATION"))
    return counts


def table(header: list[str], rows: list[list[str]]) -> str:
    """Box-drawn table, first column left-aligned, the others right-aligned."""
    widths = [max(len(r[i]) for r in [header, *rows]) for i in range(len(header))]

    def line(left: str, mid: str, right: str) -> str:
        return left + mid.join("─" * (w + 2) for w in widths) + right

    def row(cells: list[str], centre: bool = False) -> str:
        out = []
        for i, (cell, w) in enumerate(zip(cells, widths)):
            text = cell.center(w) if centre else cell.ljust(w) if i == 0 else cell.rjust(w)
            out.append(f" {text} ")
        return "│" + "│".join(out) + "│"

    lines = [line("┌", "┬", "┐"), row(header, centre=True)]
    for r in rows:
        lines += [line("├", "┼", "┤"), row(r)]
    lines.append(line("└", "┴", "┘"))
    return "\n".join(lines)


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("projects", nargs="*", metavar="PROJECT",
                        help="project names as in the CSV's project column (default: all)")
    parser.add_argument("--csv", type=Path, default=script_dir.parent / "project_dir_paths.csv",
                        help="projects CSV with project and share_path columns (default: %(default)s)")
    parser.add_argument("--share-prefix", type=Path, default=Path("/shares/sign-language.ebling.cl.uzh"),
                        help="directory share_path is relative to (default: %(default)s)")
    parser.add_argument("--out", type=Path, help="also write the counts to this CSV file")
    args = parser.parse_args()

    with open(args.csv, newline="", encoding="utf-8-sig") as f:
        share_paths = {r["project"]: r["share_path"] for r in csv.DictReader(f) if r["project"]}
    projects = args.projects or list(share_paths)
    unknown = [p for p in projects if p not in share_paths]
    if unknown:
        print(f"Not in {args.csv}: {', '.join(unknown)}", file=sys.stderr)
        return 1

    results = []  # (project, files, sentences, signs, failed)
    not_segmented = []
    for project in projects:
        eaf_dir = args.share_prefix / share_paths[project].strip("/") / "pose" / "auto_segmented"
        if not eaf_dir.is_dir():
            not_segmented.append(project)
            continue
        totals = dict.fromkeys(TIERS, 0)
        files = failed = 0
        for eaf in sorted(eaf_dir.glob("*.eaf")):
            try:
                counts = count_eaf(eaf)
            except ET.ParseError as e:
                print(f"{project}: can't parse {eaf.name}: {e}", file=sys.stderr)
                failed += 1
                continue
            files += 1
            for tier in TIERS:
                totals[tier] += counts[tier]
        results.append((project, files, totals["SENTENCE"], totals["SIGN"], failed))

    if not_segmented:
        print(f"Skipped, no pose/auto_segmented directory: {', '.join(not_segmented)}", file=sys.stderr)
    if not results:
        print("No auto_segmented directories found", file=sys.stderr)
        return 1

    # Projects sharing a top-level share directory (the SMILE1 subprojects) get a
    # subtotal row after the last of them
    groups: dict[str, list[tuple]] = {}
    for r in results:
        groups.setdefault(share_paths[r[0]].strip("/").split("/")[0], []).append(r)
    subtotals = {members[-1][0]: (f"{group} total", *(sum(m[i] for m in members) for i in (1, 2, 3, 4)))
                 for group, members in groups.items() if len(members) > 1}
    rows_with_subtotals = []
    for r in results:
        rows_with_subtotals.append(r)
        if r[0] in subtotals:
            rows_with_subtotals.append(subtotals[r[0]])

    rows = [[p, f"{n:,}", f"{s:,}", f"{g:,}"] for p, n, s, g, _ in rows_with_subtotals]
    rows.append(["Total", *(f"{sum(r[i] for r in results):,}" for i in (1, 2, 3))])
    print(table(["Project", "EAFs", "Sentences", "Signs"], rows))

    if args.out:
        with open(args.out, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["project", "eafs", "sentences", "signs", "unparsable"])
            writer.writerows([p, *(f"{n:,}" for n in counts)] for p, *counts in rows_with_subtotals)
    return 1 if any(r[4] for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
