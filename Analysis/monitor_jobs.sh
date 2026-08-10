#!/bin/bash
#SBATCH --job-name=wdl_monitor
#SBATCH --account=def-rallard
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=256M
#SBATCH --output=J-%x.%j.out
#
# Polls squeue for the current user every INTERVAL seconds and reports:
#   - how many jobs are in the queue (pending+running = "requested")
#   - how many are actually running
#   - total CPUs/RAM currently allocated to running jobs
#   - total CPUs/RAM that would be needed if every queued job ran at once
#   - job counts grouped by the first 10 characters of the job name
# Also tracks the running peak of each of those numbers, so that after the
# 3 WDL workflow instances have finished you can look at the report log and
# see the highest concurrency/resource usage that was ever reached.
#
# The monitor's own job is excluded from all counts. Once it is the only
# job left in the queue (nothing left to monitor) it prints the final peak
# summary and exits on its own, instead of idling until --time runs out.
#
# NOTE: this reports requested/allocated resources as seen by squeue, not
# measured (sstat) usage - that's what matters for sizing future submissions.
#
# Usage: sbatch monitor_wdl_jobs.sh [interval_seconds] [job_name_filter]
#   interval_seconds : how often to poll (default 600 = 10 min)
#   job_name_filter  : optional squeue -n glob/name filter, e.g. a common
#                      prefix used by miniwdl task jobs. Default: all jobs
#                      for the current user.
#
# The monitor exits when it hits the time
# limit or is cancelled, whichever comes first.

set -uo pipefail

SCRIPT_DIR="/home/felixant/scratch/Ste-JustinePacbioWGS/Analysis"
INTERVAL="${1:-600}"
NAME_FILTER="${2:-}"
SELF_JOB_ID="${SLURM_JOB_ID:-$$}"
LOGFILE="$SCRIPT_DIR/wdl_monitor_report_$(date '+%Y%m%d_%H%M%S')_${SELF_JOB_ID}.log"

peak_total=0
peak_running=0
peak_pending=0
peak_cpus_running=0
peak_mem_running=0
peak_cpus_requested=0
peak_mem_requested=0

log_line() {
	echo "$*" | tee -a "$LOGFILE"
}

print_final_summary() {
	log_line ""
	log_line "===== FINAL PEAK SUMMARY $(date '+%F %T') ====="
	log_line "Peak jobs requested (pending+running): $peak_total"
	log_line "Peak jobs running:                     $peak_running"
	log_line "Peak jobs pending:                      $peak_pending"
	log_line "Peak CPUs allocated to running jobs:    $peak_cpus_running"
	log_line "Peak RAM allocated to running jobs:     ${peak_mem_running} MB"
	log_line "Peak CPUs requested (all queued jobs):  $peak_cpus_requested"
	log_line "Peak RAM requested (all queued jobs):   ${peak_mem_requested} MB"
}

trap 'print_final_summary; exit 0' SIGTERM SIGINT

echo "timestamp,jobs_total,jobs_running,jobs_pending,cpus_running,mem_running_mb,cpus_requested,mem_requested_mb" >"$LOGFILE"

echo "Starting WDL job monitor (self job id: $SELF_JOB_ID). Polling every ${INTERVAL}s. Report log: $LOGFILE"
[ -n "$NAME_FILTER" ] && echo "Filtering jobs by name pattern: $NAME_FILTER"

while true; do
	if [ -n "$NAME_FILTER" ]; then
		squeue_out="$(squeue -h -u "$USER" -n "$NAME_FILTER" -o "%i|%t|%C|%m|%j" 2>/dev/null)"
	else
		squeue_out="$(squeue -h -u "$USER" -o "%i|%t|%C|%m|%j" 2>/dev/null)"
	fi
	# drop the monitor's own job from every count below
	squeue_out="$(echo "$squeue_out" | awk -F'|' -v self="$SELF_JOB_ID" '$1 != self')"

	read -r jobs_total jobs_running jobs_pending cpus_running mem_running cpus_requested mem_requested <<<"$(
		echo "$squeue_out" | awk -F'|' '
			{
				total++
				cpus = $3 + 0
				mem = $4
				gsub(/[^0-9.]/, "", mem)
				mem += 0
				cpus_req += cpus
				mem_req += mem
				if ($2 == "R") {
					running++
					cpus_run += cpus
					mem_run += mem
				} else if ($2 == "PD") {
					pending++
				}
			}
			END {
				print total+0, running+0, pending+0, cpus_run+0, mem_run+0, cpus_req+0, mem_req+0
			}
		'
	)"

	job_groups="$(
		echo "$squeue_out" | awk -F'|' '
			{
				group = substr($5, 1, 10)
				count[group]++
				if ($2 == "R") running[group]++
				else if ($2 == "PD") pending[group]++
			}
			END {
				for (g in count) {
					printf "%s|%d|%d|%d\n", g, count[g], running[g]+0, pending[g]+0
				}
			}
		' | sort -t'|' -k2 -rn
	)"

	if [ "$jobs_total" -eq 0 ]; then
		echo "No jobs left to monitor besides this one (self job id: $SELF_JOB_ID). Stopping."
		print_final_summary
		exit 0
	fi

	[ "$jobs_total" -gt "$peak_total" ] && peak_total=$jobs_total
	[ "$jobs_running" -gt "$peak_running" ] && peak_running=$jobs_running
	[ "$jobs_pending" -gt "$peak_pending" ] && peak_pending=$jobs_pending
	[ "$cpus_running" -gt "$peak_cpus_running" ] && peak_cpus_running=$cpus_running
	[ "$mem_running" -gt "$peak_mem_running" ] && peak_mem_running=$mem_running
	[ "$cpus_requested" -gt "$peak_cpus_requested" ] && peak_cpus_requested=$cpus_requested
	[ "$mem_requested" -gt "$peak_mem_requested" ] && peak_mem_requested=$mem_requested

	timestamp="$(date '+%F %T')"
	echo "$timestamp,$jobs_total,$jobs_running,$jobs_pending,$cpus_running,$mem_running,$cpus_requested,$mem_requested" >>"$LOGFILE"

	{
		echo "[$timestamp] Jobs: total=$jobs_total running=$jobs_running pending=$jobs_pending | Running: cpus=$cpus_running mem=${mem_running}MB | Requested(all): cpus=$cpus_requested mem=${mem_requested}MB | Peaks so far: total=$peak_total running=$peak_running cpus_running=$peak_cpus_running mem_running=${peak_mem_running}MB cpus_req=$peak_cpus_requested mem_req=${peak_mem_requested}MB"
		echo "  Job groups (by first 10 chars of name):"
		echo "$job_groups" | awk -F'|' '{ printf "    %-10s : %d (running=%d pending=%d)\n", $1, $2, $3, $4 }'
	} | tee -a "$LOGFILE"

	sleep "$INTERVAL"
done
