#!/usr/bin/env python3
"""Fail-closed SB-COVER LCOV threshold gate; counts only instrumented source lines.

Line denominator: distinct DA records inside owned src/input and src/terminal
files, excluding the optional events adapter and package-only facade metadata.
No blank/comment-only lines or test/dependency code count in denominator.
Every expected core source file must have at least one instrumented DA line.
"""
import argparse
import json
from pathlib import Path


EXCLUDED = {
    "src/input/events-adapter.lisp",
    "src/input/package.lisp",
}


def measure(lcov: Path, root: Path) -> dict:
    root = root.resolve()
    expected = {
        p.relative_to(root).as_posix()
        for p in (root / "src").rglob("*.lisp")
        if p.relative_to(root).as_posix() not in EXCLUDED
    }
    if not expected:
        raise ValueError("No owned source files found")
    # Reject impossible line numbers rather than accepting fabricated
    # executable-line denominators or a report from stale source revisions.
    line_counts = {
        name: len((root / name).read_text(encoding="utf-8").splitlines())
        for name in expected
    }
    hits: dict[str, dict[int, int]] = {}
    current = None
    for number, raw in enumerate(lcov.read_text(encoding="utf-8").splitlines(), 1):
        if raw.startswith("SF:"):
            if current is not None:
                raise ValueError(f"Nested SF at LCOV line {number}")
            file = Path(raw[3:])
            file = file if file.is_absolute() else root / file
            full = file.resolve()
            current = full.relative_to(root).as_posix() if full.is_relative_to(root) else ""
            if current in expected:
                hits.setdefault(current, {})
        elif raw.startswith("DA:"):
            if current is None:
                raise ValueError(f"DA without SF at LCOV line {number}")
            try:
                field = raw[3:].split(",")
                line, count = int(field[0]), int(field[1])
            except (ValueError, IndexError) as e:
                raise ValueError(f"Malformed DA at LCOV line {number}") from e
            if line < 1 or count < 0:
                raise ValueError(f"Invalid DA at LCOV line {number}")
            if current in expected:
                if line > line_counts[current]:
                    raise ValueError(
                        f"DA line {line} exceeds {current} "
                        f"({line_counts[current]} source lines)"
                    )
                previous = hits[current].get(line, 0)
                hits[current][line] = max(previous, count)
        elif raw == "end_of_record":
            if current is None:
                raise ValueError(f"end_of_record without SF at LCOV line {number}")
            current = None
    if current is not None:
        raise ValueError("Unterminated LCOV source record")
    missing = sorted(f for f in expected if not hits.get(f))
    if missing:
        raise ValueError("No instrumented lines for: " + ", ".join(missing))
    found = sum(sum(count > 0 for count in lines.values()) for lines in hits.values())
    total = sum(len(lines) for lines in hits.values())
    if not total:
        raise ValueError("Instrumented line denominator is zero")
    return {
        "covered_lines": found,
        "instrumented_lines": total,
        "line_coverage_percent": round(100 * found / total, 2),
        "per_file": {
            name: {"covered": sum(c > 0 for c in lines.values()),
                   "instrumented": len(lines)}
            for name, lines in sorted(hits.items())
        },
        "excluded_files": sorted(EXCLUDED),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("lcov", type=Path)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--min", type=float, default=85.0, dest="minimum")
    parser.add_argument("--out", type=Path, default=Path("coverage/coverage.json"))
    parser.add_argument("--badge", type=Path, default=Path("coverage/coverage-badge.json"))
    args = parser.parse_args()
    if not 0 <= args.minimum <= 100:
        parser.error("--min must be between 0 and 100")
    result = measure(args.lcov, args.root)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    passed = result["covered_lines"] * 100 >= args.minimum * result["instrumented_lines"]
    color = "red"
    if passed:
        color = "brightgreen" if result["line_coverage_percent"] >= 90 else "green"
    badge = {
        "schemaVersion": 1,
        "label": "coverage",
        "message": f'{result["line_coverage_percent"]:.2f}%',
        "color": color,
    }
    args.badge.parent.mkdir(parents=True, exist_ok=True)
    args.badge.write_text(json.dumps(badge, sort_keys=True) + "\n", encoding="utf-8")
    print(f'SBCL owned line coverage: {result["covered_lines"]}/'
          f'{result["instrumented_lines"]} = {result["line_coverage_percent"]:.2f}% '
          f'(minimum {args.minimum:.2f}%)')
    print("Excluded:", ", ".join(sorted(EXCLUDED)))
    return 0 if passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        raise SystemExit(f"coverage gate error: {exc}") from exc
