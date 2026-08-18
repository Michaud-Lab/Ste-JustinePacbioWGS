#!/bin/bash

# Fetches the Illumina GVCF for a sample from the staging server via rclone.
#
# This is meant to be run directly on the login node (NOT inside an sbatch job) —
# job nodes on some clusters have slow or no direct internet/staging access, which
# made the rclone step inside run_concordance.slurm take way too long. Run this first,
# then submit run_concordance.slurm (which now assumes the GVCF is already local) via sbatch.
#
# Usage: fetch_concordance_gvcf.sh -n <sample_name> -o <output_dir> [-c <config_file>] [-l <log_file>]
#   -n  Sample name (used to locate the GVCF on staging_juno)
#   -o  Output directory (a Concordance/ subdirectory will be created inside it)
#   -c  Config file (default: <here_folder>/../.myconf.json)
#   -l  Log file
#
# Exit codes:
#   0  GVCF/VCF already local, or downloaded successfully
#   1  Download error
#   2  GVCF not found on staging server — concordance should be skipped for this sample

set -eo pipefail

usage() {
    echo "Usage: $0 -n <sample_name> -o <output_dir> [-c <config_file>] [-l <log_file>]"
    1>&2; exit 1
}

here_folder="$(cd "$(dirname "$0")" && pwd)"
sample_name=""
output_dir=""
log_file=""
config_file="$here_folder/../.myconf.json"
while getopts ":n:o:l:c:" opt; do
    case "${opt}" in
        n)  sample_name="${OPTARG}" ;;
        o)  output_dir="${OPTARG}" ;;
        l)  log_file="${OPTARG}" ;;
        c)  config_file="${OPTARG}" ;;
        :)  echo "Error: -${OPTARG} requires an argument."; usage ;;
        *)  usage ;;
    esac
done
log_step() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; [ -n "${log_file:-}" ] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$log_file"; }

if [ -z "$sample_name" ] || [ -z "$output_dir" ]; then
    echo "Error: -n and -o are required."
    usage
fi

REMOTE_BASE_PREFIX=$(jq -r '.Rclone.short_reads_depot' "$config_file")

concordance_dir="$output_dir/Concordance"
mkdir -p "$concordance_dir"

remote_dir="${REMOTE_BASE_PREFIX}/${sample_name}"
sr_gvcf_name="${sample_name}.dragen.hard-filtered.gvcf.gz"
sr_vcf="$concordance_dir/${sample_name}.dragen.hard-filtered.vcf.gz"
sr_gvcf="${concordance_dir}/${sr_gvcf_name}"

if [ -f "$sr_gvcf" ] || [ -f "$sr_vcf" ]; then
    echo "${sample_name}: GVCF/VCF already local, skipping download"
    exit 0
fi

# ── Locate GVCF on staging server ────────────────────────────────────────────
echo "Searching for ${sr_gvcf_name} on ${remote_dir} with command:"
cat << EOF
rclone lsf --format "tp" --files-only -R --include "$sr_gvcf_name" "$remote_dir"
EOF
remote_listing=$(rclone lsf --format "tp" --files-only -R --include "$sr_gvcf_name" "$remote_dir" 2>/dev/null || true)

if [ -z "$remote_listing" ]; then
    echo "WARNING: ${sr_gvcf_name} not found on staging_juno for sample ${sample_name}. Skipping concordance."
    log_step "SKIPPED: concordance fetch for ${sample_name} (GVCF not found on staging)"
    exit 2
else
    echo "Found these results:"
    echo "$remote_listing"
fi

result_count=$(echo "$remote_listing" | wc -l)
if [ "$result_count" -gt 1 ]; then
    echo "Found ${result_count} matches for ${sr_gvcf_name} — selecting the most recent."
fi
# Each line is "YYYY-MM-DD HH:MM:SS path"; reverse-sort picks the most recent, awk extracts the path
remote_result=$(echo "$remote_listing" | sort -r | head -1 | awk -F';' '{print $NF}')

# ── Download GVCF (and index if available) ───────────────────────────────────
echo "Found: ${remote_result} — downloading to ${concordance_dir}/ with command:"
cat << EOF
rclone copy "${remote_dir}/${remote_result}"      "$concordance_dir/"
EOF
rclone copy "${remote_dir}/${remote_result}"      "$concordance_dir/"
rclone copy "${remote_dir}/${remote_result}.tbi"  "$concordance_dir/" 2>/dev/null || true

if [ ! -f "$sr_gvcf" ]; then
    echo "ERROR: Download of ${sr_gvcf_name} failed."
    log_step "FAILED: concordance fetch for ${sample_name} (download error)"
    exit 1
fi

log_step "SUCCESS: concordance fetch for ${sample_name}"
