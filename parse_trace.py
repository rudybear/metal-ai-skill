#!/usr/bin/env python3
"""
parse_trace.py — Parse xctrace XML exports into structured data.

Usage:
    # Export from xctrace first:
    xcrun xctrace export --input trace.trace --output events.xml \
      --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-driver-event-intervals"]'

    # Then parse:
    python3 parse_trace.py events.xml
    python3 parse_trace.py events.xml --format json
    python3 parse_trace.py events.xml --format csv
    python3 parse_trace.py events.xml --summary
"""

import argparse
import csv
import json
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from typing import Any


def build_ref_map(root: ET.Element) -> dict[str, ET.Element]:
    """Build a map of id -> element for resolving ref nodes."""
    id_map = {}
    for elem in root.iter():
        eid = elem.get("id")
        if eid is not None:
            id_map[eid] = elem
    return id_map


def resolve(elem: ET.Element, id_map: dict[str, ET.Element]) -> ET.Element:
    """Resolve a ref node to its original element."""
    ref = elem.get("ref")
    if ref and ref in id_map:
        return id_map[ref]
    return elem


def get_value(elem: ET.Element, id_map: dict[str, ET.Element]) -> str:
    """Get the display value of an element, resolving refs."""
    resolved = resolve(elem, id_map)
    return resolved.get("fmt", resolved.text or "")


def parse_table(xml_path: str) -> tuple[list[str], list[dict[str, str]]]:
    """Parse an xctrace XML export into headers + rows of dicts."""
    tree = ET.parse(xml_path)
    root = tree.getroot()
    id_map = build_ref_map(root)

    # Extract schema/column info from the first row
    rows_data = []
    headers = []

    for row in root.findall(".//row"):
        cols = list(row)
        if not headers:
            # Use tag names as headers (or generate col_0, col_1, ...)
            headers = [col.tag for col in cols]
            # Deduplicate headers
            seen = Counter()
            deduped = []
            for h in headers:
                seen[h] += 1
                if seen[h] > 1:
                    deduped.append(f"{h}_{seen[h]}")
                else:
                    deduped.append(h)
            headers = deduped

        row_dict = {}
        for i, col in enumerate(cols):
            key = headers[i] if i < len(headers) else f"col_{i}"
            row_dict[key] = get_value(col, id_map)
        rows_data.append(row_dict)

    return headers, rows_data


def print_summary(headers: list[str], rows: list[dict[str, str]]) -> None:
    """Print a summary of the parsed data."""
    print(f"Total rows: {len(rows)}")
    print(f"Columns ({len(headers)}): {', '.join(headers)}")
    print()

    # Count unique values per column (first 5 columns)
    for col in headers[:5]:
        values = [r.get(col, "") for r in rows]
        unique = set(values)
        counter = Counter(values)
        print(f"  {col}:")
        print(f"    Unique values: {len(unique)}")
        if len(unique) <= 10:
            for val, count in counter.most_common():
                print(f"      {val}: {count}")
        else:
            for val, count in counter.most_common(5):
                print(f"      {val}: {count}")
            print(f"      ... and {len(unique) - 5} more")
        print()


def print_tsv(headers: list[str], rows: list[dict[str, str]], limit: int) -> None:
    """Print as TSV."""
    print("\t".join(headers))
    for row in rows[:limit]:
        print("\t".join(row.get(h, "") for h in headers))
    if len(rows) > limit:
        print(f"... ({len(rows) - limit} more rows)")


def print_json(headers: list[str], rows: list[dict[str, str]], limit: int) -> None:
    """Print as JSON."""
    output = rows[:limit]
    json.dump(output, sys.stdout, indent=2)
    print()
    if len(rows) > limit:
        print(f"// ... ({len(rows) - limit} more rows)", file=sys.stderr)


def print_csv_output(
    headers: list[str], rows: list[dict[str, str]], limit: int
) -> None:
    """Print as CSV."""
    writer = csv.DictWriter(sys.stdout, fieldnames=headers)
    writer.writeheader()
    for row in rows[:limit]:
        writer.writerow({h: row.get(h, "") for h in headers})
    if len(rows) > limit:
        print(f"# ... ({len(rows) - limit} more rows)", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        description="Parse xctrace XML exports into structured data"
    )
    parser.add_argument("xml_file", help="Path to exported XML file")
    parser.add_argument(
        "--format",
        choices=["tsv", "json", "csv"],
        default="tsv",
        help="Output format (default: tsv)",
    )
    parser.add_argument(
        "--limit", type=int, default=100, help="Max rows to output (default: 100)"
    )
    parser.add_argument(
        "--summary", action="store_true", help="Print summary statistics"
    )
    args = parser.parse_args()

    try:
        headers, rows = parse_table(args.xml_file)
    except ET.ParseError as e:
        print(f"ERROR: Failed to parse XML: {e}", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print(f"ERROR: File not found: {args.xml_file}", file=sys.stderr)
        sys.exit(1)

    if not rows:
        print("No data rows found in the XML export.", file=sys.stderr)
        sys.exit(0)

    if args.summary:
        print_summary(headers, rows)
    elif args.format == "json":
        print_json(headers, rows, args.limit)
    elif args.format == "csv":
        print_csv_output(headers, rows, args.limit)
    else:
        print_tsv(headers, rows, args.limit)


if __name__ == "__main__":
    main()
