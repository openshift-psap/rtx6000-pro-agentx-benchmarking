#!/usr/bin/env python3
"""Validate one AIPerf AgentX profile export."""

import argparse
import json
import math
from pathlib import Path


def average(result: dict, key: str) -> float:
    value = result.get(key, 0)
    if isinstance(value, dict):
        value = value.get("avg", 0)
    return float(value or 0)


def validate(result: dict, scenario: str = "inferencex-agentx-mvp") -> tuple[list[str], dict[str, float]]:
    if not isinstance(result, dict):
        return ["export_is_object"], {}
    metadata = result.get("metadata", {})
    if not isinstance(metadata, dict):
        return ["metadata_is_object"], {}
    counts = {
        "requests": average(result, "request_count"),
        "completed": average(result, "completed_request_count"),
        "errors": average(result, "error_request_count"),
        "error_rate": average(result, "request_error_rate"),
    }
    checks = [
        ("complete", result.get("is_complete") is True),
        ("not_cancelled", result.get("was_cancelled") is False),
        ("submission_valid", metadata.get("submission_valid") is True),
        ("scenario_matches", metadata.get("scenario") == scenario),
        ("requests_positive", counts["requests"] > 0),
        ("completed_matches_requests", math.isclose(counts["completed"], counts["requests"], rel_tol=0, abs_tol=1e-9)),
        ("zero_errors", counts["errors"] == 0 and counts["error_rate"] == 0),
    ]
    return [name for name, ok in checks if not ok], counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export", type=Path, help="Path to profile_export_aiperf.json")
    parser.add_argument("--scenario", default="inferencex-agentx-mvp")
    parser.add_argument("--summary-tsv", action="store_true", help="Print request, completed, error and error-rate values")
    args = parser.parse_args()
    try:
        result = json.loads(args.export.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"cannot read AIPerf export: {exc}")
        return 2
    try:
        failures, counts = validate(result, args.scenario)
    except (TypeError, ValueError) as exc:
        print(f"invalid: export has an invalid metric value ({exc})")
        return 1
    if failures:
        print("invalid: " + ", ".join(failures))
        return 1
    if args.summary_tsv:
        print("\t".join(str(counts[k]) for k in ("requests", "completed", "errors", "error_rate")))
    else:
        print(f"valid: {counts['requests']:g} requests, zero errors, submission_valid=true")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
