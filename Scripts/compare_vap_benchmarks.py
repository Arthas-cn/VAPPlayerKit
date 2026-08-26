#!/usr/bin/env python3
"""Compare the two raw benchmark reports using only valid samples."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path


def load(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def valid_runs(report: dict) -> list[dict]:
    # Do not trust a missing/incorrect validity flag. A sample is comparable
    # only when the benchmark rendered something and reported no error.
    return [
        run
        for run in report.get("runs", [])
        if bool(run.get("valid"))
        and float(run.get("rendered", 0)) > 0
        and run.get("error") in (None, "")
    ]


def validate_pair(new: dict, old: dict) -> None:
    mismatches = []
    for key in ("asset", "asset_bytes", "system", "window_seconds"):
        if new.get(key) != old.get(key):
            mismatches.append(f"{key}: {new.get(key)!r} != {old.get(key)!r}")
    if mismatches:
        raise SystemExit("benchmark metadata mismatch: " + "; ".join(mismatches))


def values(report: dict, phase: str, key: str) -> list[float]:
    return [
        float(run[key])
        for run in valid_runs(report)
        if run.get("phase") == phase and run.get(key) is not None
    ]


def stage_values(report: dict, phase: str, name: str) -> list[float]:
    return [
        float(run.get("prepare_stages_ms", {}).get(name, 0))
        for run in valid_runs(report)
        if run.get("phase") == phase and name in run.get("prepare_stages_ms", {})
    ]


def median(items: list[float]) -> float | None:
    return statistics.median(items) if items else None


def fmt(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.2f}"


def improvement(old: float | None, new: float | None) -> str:
    if old is None or new is None or old == 0:
        return "n/a"
    return f"{(old - new) / old * 100:+.1f}%"


def metric_row(label: str, key: str, phase: str, new: dict, old: dict) -> str:
    new_value = median(values(new, phase, key))
    old_value = median(values(old, phase, key))
    return f"| {phase} | {label} | {fmt(new_value)} | {fmt(old_value)} | {improvement(old_value, new_value)} |"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("new", type=Path)
    parser.add_argument("old", type=Path)
    parser.add_argument("-o", "--output", type=Path)
    args = parser.parse_args()

    new = load(args.new)
    old = load(args.old)
    validate_pair(new, old)
    new_valid = valid_runs(new)
    old_valid = valid_runs(old)

    lines = [
        "# VAPPlayerKit vs vap-master corrected benchmark",
        "",
        f"- device: {new.get('device')}, iOS {new.get('system')}",
        f"- asset: {new.get('asset')}, {new.get('asset_bytes')} bytes",
        f"- valid runs: new {len(new_valid)}/{len(new.get('runs', []))}, old {len(old_valid)}/{len(old.get('runs', []))}",
        "- build: Release, signed device build",
        "- window: 2 seconds; one process-cold run and four same-process warm runs",
        "",
        "| phase | metric | VAPPlayerKit | vap-master | improvement |",
        "| --- | --- | ---: | ---: | ---: |",
        metric_row("API -> ready (ms)", "prepare_api_to_ready_ms", "cold", new, old),
        metric_row("API -> first GPU submission (ms)", "play_to_first_frame_ms", "cold", new, old),
        metric_row("API -> ready (ms)", "prepare_api_to_ready_ms", "warm", new, old),
        metric_row("API -> first GPU submission (ms)", "play_to_first_frame_ms", "warm", new, old),
        "",
        "## Diagnostic counters",
        "",
        "| phase | metric | VAPPlayerKit median | vap-master median | interpretation |",
        "| --- | --- | ---: | ---: | --- |",
    ]
    for phase in ("cold", "warm"):
        for key, label in (("rendered", "rendered"), ("decoded", "decoded"), ("dropped", "dropped")):
            new_value = median(values(new, phase, key))
            old_value = median(values(old, phase, key))
            interpretation = "same layer, but not a strict cross-implementation equivalence" if key in {"rendered", "decoded"} else "zero in this run; not a stress-test result"
            lines.append(f"| {phase} | {label} | {fmt(new_value)} | {fmt(old_value)} | {interpretation} |")
    lines += [
        "",
        "## VAPPlayerKit prepare stages (new implementation only)",
        "",
        "| phase | stage | median ms |",
        "| --- | --- | ---: |",
    ]
    for phase in ("cold", "warm"):
        for stage in ("inspection", "frame_source", "renderer", "dynamic_resolve", "dynamic_upload", "audio"):
            lines.append(f"| {phase} | {stage} | {fmt(median(stage_values(new, phase, stage)))} |")
    lines += [
        "",
        "## Metric validity",
        "",
        "| metric | status | reason |",
        "| --- | --- | --- |",
        "| prepare_api_to_ready_ms | primary comparison | both sides start at the benchmark API call and stop at the ready/prepare callback; callback scheduling is included |",
        "| prepare_ms | diagnostic only | implementation-internal prepare duration; useful for stage analysis but not the headline cross-implementation metric |",
        "| play_to_first_frame_ms | primary comparison | both sides measure API call to first GPU/display submission; excludes later GPU completion |",
        "| first_frame_ms | diagnostic only | implementation-specific duration origin differs; do not compare directly |",
        "| rendered / decoded | diagnostic only | event layers and decoder APIs differ; use for regressions within one implementation |",
        "| dropped / drawable_failures / decoder_rebuilds | trigger counters | zero means no trigger in this asset/window, not a general performance guarantee |",
        "| session_finished | excluded | the collector stops after reading the sample, so it is not a stable per-sample metric |",
        "",
        "p95 is intentionally not reported: four warm samples and one cold sample are exploratory, not enough for a reliable tail estimate.",
    ]
    output = "\n".join(lines) + "\n"
    if args.output:
        args.output.write_text(output, encoding="utf-8")
    else:
        print(output, end="")


if __name__ == "__main__":
    main()
