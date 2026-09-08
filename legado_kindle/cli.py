from __future__ import annotations

import argparse
import json
from pathlib import Path

from .backup import BackupBundle, BackupError
from .rules import SourceDefinition
from .state import StateError, import_bundle


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Inspect and import Legado Android backups")
    subparsers = parser.add_subparsers(dest="command", required=True)

    inspect = subparsers.add_parser("inspect", help="print a value-redacted structural report")
    inspect.add_argument("archive", type=Path)

    source_report = subparsers.add_parser(
        "source-report",
        help="report source-rule capabilities without printing source values",
    )
    source_report.add_argument("archive", type=Path)

    materialize = subparsers.add_parser(
        "materialize",
        help="import an Android backup into the versioned Kindle state layout",
    )
    materialize.add_argument("source", type=Path)
    materialize.add_argument("destination", type=Path)

    return parser


def main(argv: list[str] | None = None) -> None:
    args = _build_parser().parse_args(argv)
    try:
        archive_path = args.archive if args.command in {"inspect", "source-report"} else args.source
        bundle = BackupBundle.load(archive_path)
        if args.command == "inspect":
            print(json.dumps(bundle.summary().as_dict(), ensure_ascii=False, indent=2))
        elif args.command == "source-report":
            sources = bundle.json("bookSource.json")
            if not isinstance(sources, list):
                sources = []
            reports = [SourceDefinition.from_mapping(source).compatibility_report() for source in sources if isinstance(source, dict)]
            capability_totals: dict[str, int] = {}
            for report in reports:
                for name, count in report["counts"].items():
                    capability_totals[name] = capability_totals.get(name, 0) + count
            print(json.dumps({
                "source_count": len(reports),
                "text_source_count": sum(report["text_source"] for report in reports),
                "sources_with_unsupported_capabilities": sum(
                    bool(report["unsupported_capabilities"]) for report in reports
                ),
                "capability_totals": dict(sorted(capability_totals.items())),
                "sources": reports,
            }, ensure_ascii=False, indent=2))
        elif args.command == "materialize":
            state = import_bundle(bundle, args.destination)
            print(json.dumps(state.manifest(), ensure_ascii=False, indent=2))
    except BackupError as exc:
        raise SystemExit(f"error: {exc}") from exc
    except StateError as exc:
        raise SystemExit(f"error: {exc}") from exc
