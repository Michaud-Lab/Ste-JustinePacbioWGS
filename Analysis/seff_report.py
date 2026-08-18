#!/usr/bin/env python3
#
# Walks a miniwdl run folder, finds every slurm-<id>.out log left behind by
# the workflow's task directories, and runs `seff` on each job id to report
# its resource efficiency. Directories holding more than one slurm-*.out file
# indicate the task was restarted (e.g. after a preemption or OOM retry) -
# every attempt is reported, flagged as RESTARTED, and numbered by attempt.
#
# Usage: seff_report.py <miniwdl_run_dir> [-o OUTPUT]
#   miniwdl_run_dir : e.g. /home/felixant/scratch/p155 (the folder containing
#                     the "_LAST" symlink), or the resolved run dir itself.
#   -o/--output     : write the report here instead of the default
#                     <miniwdl_run_dir>/resource_efficiency_report_<basename>.log
#                     (the report is always printed to stdout too).

import argparse
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

SLURM_OUT_RE = re.compile(r"^slurm-(\d+)\.out$")

SEFF_FIELDS = {
    "state": re.compile(r"^State:\s*(.+)$", re.MULTILINE),
    "cores": re.compile(r"^Cores(?: per node)?:\s*(.+)$", re.MULTILINE),
    "cpu_time": re.compile(r"^CPU Utilized:\s*(.+)$", re.MULTILINE),
    "cpu_eff": re.compile(r"^CPU Efficiency:\s*(.+)$", re.MULTILINE),
    "wall_time": re.compile(r"^Job Wall-clock time:\s*(.+)$", re.MULTILINE),
    "mem_util": re.compile(r"^Memory Utilized:\s*(.+)$", re.MULTILINE),
    "mem_eff": re.compile(r"^Memory Efficiency:\s*(.+)$", re.MULTILINE),
}

NA = "N/A"


def find_run_dir(root):
    last = root / "_LAST"
    if last.is_dir():
        return last
    return root


def run_seff(job_id):
    try:
        result = subprocess.run(
            ["seff", job_id], capture_output=True, text=True, timeout=30
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {"error": f"seff invocation failed: {exc}"}

    output = result.stdout
    if result.returncode != 0 or not output.strip():
        message = (output + result.stderr).strip() or f"seff exited {result.returncode}"
        return {"error": message}

    parsed = {}
    for key, pattern in SEFF_FIELDS.items():
        match = pattern.search(output)
        parsed[key] = match.group(1).strip() if match else NA

    parsed["state"] = re.sub(r"\s*\(exit code[^)]*\)", "", parsed["state"])

    requested_match = re.search(r"of\s+([\d.]+\s*[A-Za-z]+)", parsed["mem_eff"])
    requested_raw = requested_match.group(1) if requested_match else NA
    parsed["mem_util"] = to_gb_str(parsed["mem_util"])
    parsed["mem_requested"] = to_gb_str(requested_raw)

    for key in ("cpu_eff", "mem_eff"):
        pct = re.match(r"([\d.]+%)", parsed[key])
        if pct:
            parsed[key] = pct.group(1)
    return parsed


def gather(run_dir):
    """Returns a list of task dirs, each a dict with 'dir' (relative path)
    and 'attempts' (list of job ids, sorted oldest-first by job id)."""
    tasks = []
    for dirpath, _dirnames, filenames in os.walk(str(run_dir), followlinks=True):
        job_ids = []
        for name in filenames:
            m = SLURM_OUT_RE.match(name)
            if m:
                job_ids.append(int(m.group(1)))
        if job_ids:
            job_ids.sort()
            rel = str(Path(dirpath).relative_to(run_dir))
            tasks.append({"dir": rel, "attempts": job_ids})
    tasks.sort(key=lambda t: t["dir"])
    return tasks


def parse_hms(time_str):
    """'D-HH:MM:SS' or 'HH:MM:SS' -> total seconds. Returns None if unparseable."""
    if not time_str or time_str == NA:
        return None
    days = 0
    if "-" in time_str:
        day_part, time_str = time_str.split("-", 1)
        try:
            days = int(day_part)
        except ValueError:
            return None
    parts = time_str.split(":")
    try:
        parts = [int(p) for p in parts]
    except ValueError:
        return None
    while len(parts) < 3:
        parts.insert(0, 0)
    h, m, s = parts[-3:]
    return days * 86400 + h * 3600 + m * 60 + s


def format_hms(total_seconds):
    if total_seconds is None:
        return NA
    total_seconds = int(round(total_seconds))
    days, rem = divmod(total_seconds, 86400)
    h, rem = divmod(rem, 3600)
    m, s = divmod(rem, 60)
    if days:
        return f"{days}-{h:02d}:{m:02d}:{s:02d}"
    return f"{h:02d}:{m:02d}:{s:02d}"


def parse_percent(eff_str):
    if not eff_str or eff_str == NA:
        return None
    m = re.match(r"([\d.]+)%", eff_str.strip())
    return float(m.group(1)) if m else None


def parse_mem_mb(mem_str):
    if not mem_str or mem_str == NA:
        return None
    m = re.match(r"([\d.]+)\s*([A-Za-z]+)", mem_str.strip())
    if not m:
        return None
    value, unit = float(m.group(1)), m.group(2).upper()
    scale = {"KB": 1 / 1024, "MB": 1, "GB": 1024, "TB": 1024 * 1024}
    return value * scale.get(unit, 1)


def to_gb_str(mem_str):
    """Any 'seff'-style memory string ('35.43 MB', '1.20 GB', ...) -> 'X.XX GB'."""
    mb = parse_mem_mb(mem_str)
    return f"{mb / 1024:.2f} GB" if mb is not None else NA


def parse_gb(gb_str):
    if not gb_str or gb_str == NA:
        return None
    m = re.match(r"([\d.]+)\s*GB", gb_str.strip())
    return float(m.group(1)) if m else None


def build_report(run_dir, tasks):
    lines = []
    rows = []  # flat list of per-job dicts, for the summary pass

    header = (
        f"{'Directory':<55} {'Attempt':<9} {'JobID':<10} {'State':<20} "
        f"{'Cores':<6} {'CPU Time':<11} {'CPU Eff':<9} {'Wall Time':<11} "
        f"{'Mem Util':<10} {'Mem Req':<10} {'Mem Eff':<9}"
    )
    lines.append(header)
    lines.append("-" * len(header))

    for task in tasks:
        attempts = task["attempts"]
        restarted = len(attempts) > 1
        for idx, job_id in enumerate(attempts, start=1):
            info = run_seff(str(job_id))
            if "error" in info:
                row_display = {
                    "state": f"ERROR: {info['error']}",
                    "cores": NA,
                    "cpu_time": NA,
                    "cpu_eff": NA,
                    "wall_time": NA,
                    "mem_util": NA,
                    "mem_requested": NA,
                    "mem_eff": NA,
                }
            else:
                row_display = info

            attempt_label = f"{idx}/{len(attempts)}" + (" R" if restarted else "")
            lines.append(
                f"{task['dir']:<55} {attempt_label:<9} {job_id:<10} "
                f"{row_display['state']:<20} {row_display['cores']:<6} "
                f"{row_display['cpu_time']:<11} {row_display['cpu_eff']:<9} "
                f"{row_display['wall_time']:<11} {row_display['mem_util']:<10} "
                f"{row_display['mem_requested']:<10} {row_display['mem_eff']:<9}"
            )
            rows.append(
                {
                    "dir": task["dir"],
                    "job_id": job_id,
                    "restarted": restarted,
                    **row_display,
                }
            )

    return "\n".join(lines), rows


def build_summary(rows):
    lines = ["", "===== SUMMARY =====", ""]

    total_jobs = len(rows)
    task_dirs = {r["dir"] for r in rows}
    restarted_dirs = sorted({r["dir"] for r in rows if r["restarted"]})
    errored = [r for r in rows if str(r["state"]).startswith("ERROR")]

    lines.append(f"Task directories:     {len(task_dirs)}")
    lines.append(f"Slurm jobs (attempts): {total_jobs}")
    lines.append(f"Restarted directories: {len(restarted_dirs)}")
    for d in restarted_dirs:
        n = sum(1 for r in rows if r["dir"] == d)
        lines.append(f"  - {d} ({n} attempts)")
    if errored:
        lines.append(f"Jobs seff could not report on: {len(errored)}")

    state_counts = Counter(r["state"] for r in rows if not str(r["state"]).startswith("ERROR"))
    if state_counts:
        lines.append("")
        lines.append("Job states:")
        for state, count in sorted(state_counts.items(), key=lambda kv: -kv[1]):
            lines.append(f"  {state:<25} {count}")

    for r in rows:
        r["_wall_secs"] = parse_hms(r["wall_time"])
        r["_cpu_secs"] = parse_hms(r["cpu_time"])
        r["_cpu_eff_pct"] = parse_percent(r["cpu_eff"])
        r["_mem_eff_pct"] = parse_percent(r["mem_eff"])
        r["_mem_util_gb"] = parse_gb(r["mem_util"])

    cpu_secs = [r["_cpu_secs"] for r in rows if r["_cpu_secs"] is not None]
    wall_rows = [r for r in rows if r["_wall_secs"] is not None]
    mem_gb = [r["_mem_util_gb"] for r in rows if r["_mem_util_gb"] is not None]

    lines.append("")
    if cpu_secs:
        lines.append(f"Total CPU time (all attempts):   {format_hms(sum(cpu_secs))}")
    if wall_rows:
        total_wall = sum(r["_wall_secs"] for r in wall_rows)
        longest = max(wall_rows, key=lambda r: r["_wall_secs"])
        lines.append(f"Total wall-clock time (summed):  {format_hms(total_wall)}")
        lines.append(
            f"Longest single job wall-time:     {format_hms(longest['_wall_secs'])} "
            f"({longest['dir']}, job {longest['job_id']})"
        )
    if mem_gb:
        lines.append(f"Total memory utilized (summed):   {sum(mem_gb):.2f} GB")

    # Efficiency stats exclude jobs under 1 minute of wall-clock time - their
    # efficiency numbers are dominated by fixed job-startup overhead and are
    # not representative of actual resource usage.
    MIN_WALL_SECS = 60
    eff_rows = [r for r in wall_rows if r["_wall_secs"] >= MIN_WALL_SECS]
    skipped = len(wall_rows) - len(eff_rows)

    lines.append("")
    if skipped:
        lines.append(
            f"(excluding {skipped} job(s) under 1 minute of wall-clock time from "
            f"the efficiency stats below)"
        )

    cpu_eff_pairs = [
        (r["_cpu_eff_pct"], r["_wall_secs"]) for r in eff_rows if r["_cpu_eff_pct"] is not None
    ]
    if cpu_eff_pairs:
        effs = [e for e, _ in cpu_eff_pairs]
        weighted_avg = sum(e * w for e, w in cpu_eff_pairs) / sum(w for _, w in cpu_eff_pairs)
        lines.append(
            f"CPU efficiency:    avg {sum(effs)/len(effs):.2f}%  "
            f"wall-time-weighted avg {weighted_avg:.2f}%  "
            f"min {min(effs):.2f}%  max {max(effs):.2f}%"
        )

    mem_eff_pairs = [
        (r["_mem_eff_pct"], r["_wall_secs"]) for r in eff_rows if r["_mem_eff_pct"] is not None
    ]
    if mem_eff_pairs:
        effs = [e for e, _ in mem_eff_pairs]
        weighted_avg = sum(e * w for e, w in mem_eff_pairs) / sum(w for _, w in mem_eff_pairs)
        lines.append(
            f"Memory efficiency: avg {sum(effs)/len(effs):.2f}%  "
            f"wall-time-weighted avg {weighted_avg:.2f}%  "
            f"min {min(effs):.2f}%  max {max(effs):.2f}%"
        )

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path, help="miniwdl run folder (e.g. .../p155)")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help=(
            "write the report to this file instead of the default "
            "<run_dir>/resource_efficiency_report_<run_dir_basename>.log"
        ),
    )
    args = parser.parse_args()

    root = args.run_dir.resolve()
    if not root.is_dir():
        sys.exit(f"error: {root} is not a directory")

    run_dir = find_run_dir(root)
    out_dir = run_dir / "out"
    if not out_dir.is_dir():
        print(
            f"warning: {run_dir}/out not found - this run does not look like it "
            f"completed successfully. Reporting on jobs found so far anyway.",
            file=sys.stderr,
        )

    tasks = gather(run_dir)
    if not tasks:
        sys.exit(f"no slurm-*.out files found under {run_dir}")

    table, rows = build_report(run_dir, tasks)
    summary = build_summary(rows)
    full_report = f"Run directory: {run_dir}\n\n{table}\n{summary}\n"

    output_path = args.output or root / f"resource_efficiency_report_{root.name}.log"
    print(full_report)
    output_path.write_text(full_report)
    print(f"Report written to {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
