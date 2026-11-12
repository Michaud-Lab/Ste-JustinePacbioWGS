#!/bin/bash
#
# Confirms which files listed in file.tsv are actually on the CQDG staging
# bucket, by asking rclone to compare each local file against the remote
# object by checksum (not by re-reading a past run's log - a run's rclone
# log only shows what THAT run did, and after several separate attempts
# (dry-runs, timeouts, interactive re-runs, ...) the log directory can hold
# many partial/overlapping logs, none of which reflect the live state of
# the bucket).
#
# Writes one file per outcome, one relpath per line (paths are relative to
# both $source_dir and the bucket root, same as upload_to_cqdg.sh's
# --files-from-raw list):
#   confirmed_<ts>.log     present on the remote with a matching checksum -
#                          this is the "already sent successfully" list.
#                          Feed it to upload_to_cqdg.sh -x to skip these on
#                          a future run without re-checksumming them.
#   missing_<ts>.log       not present on the remote yet
#   differs_<ts>.log       present on the remote but with a different
#                          checksum (partial/corrupted upload - needs re-send)
#   check_errors_<ts>.log  rclone couldn't read/hash the local or remote
#                          copy (e.g. a network hiccup) - inconclusive,
#                          treat as not-yet-confirmed and retry
#
# This has to re-read every local file to hash it, so for ~9 TB of BAMs it
# is a slow, long-running operation in its own right - see cqdg_verify.slurm.
#
# The CQDG working directory (where file.tsv lives and logs/ get written) is
# read from a config file's Paths.WGS_folder, not derived from this script's
# own location - dirname "$0" is unreliable under Slurm (sbatch runs a spool
# copy of the script, not the original file).
#
# Usage: verify_cqdg_transfer.sh [-c config_file] [-t file.tsv] [-s source_dir] [-d dest_remote] [-l log_dir] [--size-only]
#   -c  Path to the WGS config JSON (default: $WGS_CONFIG_FILE)
#   -t  Path to file.tsv (default: file.tsv under Paths.WGS_folder/CQDG)
#   -s  Local source dir that submitter_file_name paths are relative to
#       (default: the CQDG_Deliverables dir generate_file_tsv.sh reads from)
#   -d  Rclone destination remote:bucket (default: cqdg-staging:chusj-decodeur-staging-sd4h)
#   -l  Directory to write logs into (default: logs/ under Paths.WGS_folder/CQDG)
#   --size-only  Compare sizes only, skip re-hashing every file (much
#                faster, weaker guarantee - use for a quick sanity check)

set -euo pipefail

config_file="${WGS_CONFIG_FILE:-}"
tsv=""
source_dir="/home/felixant/projects/ctb-rallard/COMMUN/PacBioData/CQDG_Deliverables"
dest_remote="cqdg-staging:chusj-decodeur-staging-sd4h"
log_dir=""
size_only=0

usage() { echo "Usage: $0 [-c config_file] [-t file.tsv] [-s source_dir] [-d dest_remote] [-l log_dir] [--size-only]" 1>&2; exit 1; }

args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --size-only) size_only=1; shift ;;
        *) args+=("$1"); shift ;;
    esac
done
set -- "${args[@]}"

while getopts ":c:t:s:d:l:" opt; do
    case "${opt}" in
        c) config_file="${OPTARG}" ;;
        t) tsv="${OPTARG}" ;;
        s) source_dir="${OPTARG}" ;;
        d) dest_remote="${OPTARG}" ;;
        l) log_dir="${OPTARG}" ;;
        :) echo "Error: -${OPTARG} requires an argument." 1>&2; usage ;;
        *) usage ;;
    esac
done

if [ -z "$config_file" ]; then
    echo "Error: no config file given - set \$WGS_CONFIG_FILE or pass -c <config_file>." 1>&2
    exit 1
fi
[ -f "$config_file" ] || { echo "Error: config file not found: $config_file" 1>&2; exit 1; }

wgs_folder="$(jq -r '.Paths.WGS_folder // empty' "$config_file")"
[ -n "$wgs_folder" ] || { echo "Error: Paths.WGS_folder not set in config file: $config_file" 1>&2; exit 1; }
cqdg_dir="$wgs_folder/CQDG"

[ -n "$tsv" ] || tsv="$cqdg_dir/file.tsv"
[ -n "$log_dir" ] || log_dir="$cqdg_dir/logs"

[ -f "$tsv" ] || { echo "Error: tsv not found: $tsv" 1>&2; exit 1; }
[ -d "$source_dir" ] || { echo "Error: source dir not found: $source_dir" 1>&2; exit 1; }

mkdir -p "$log_dir"
timestamp="$(date +%Y%m%d_%H%M%S)"
check_log="$log_dir/rclone_check_${timestamp}.log"
confirmed_log="$log_dir/confirmed_${timestamp}.log"
missing_log="$log_dir/missing_${timestamp}.log"
differs_log="$log_dir/differs_${timestamp}.log"
check_errors_log="$log_dir/check_errors_${timestamp}.log"
filelist="$(mktemp)"
trap 'rm -f "$filelist"' EXIT

bucket_name="${dest_remote#*:}"
prefix_regex="^[A-Za-z0-9_-]+://${bucket_name}/"

row_count=0
skipped=0
missing_source=0
: > "$filelist"
: > "$missing_log"
while IFS=$'\t' read -r -a fields; do
    submitter_file_name="${fields[3]:-}"
    [ -z "$submitter_file_name" ] && continue
    if [[ "$submitter_file_name" =~ $prefix_regex ]]; then
        relpath="${submitter_file_name#*://*/}"
        if [ ! -e "$source_dir/$relpath" ]; then
            # Can't verify a file that isn't there to hash - it's certainly
            # not confirmed, so it goes straight into missing_log.
            printf '%s\n' "$relpath" >> "$missing_log"
            missing_source=$((missing_source + 1))
            continue
        fi
        printf '%s\n' "$relpath" >> "$filelist"
        row_count=$((row_count + 1))
    else
        echo "WARNING: submitter_file_name doesn't match expected 'scheme://${bucket_name}/...' format, skipped: $submitter_file_name" 1>&2
        skipped=$((skipped + 1))
    fi
done < <(tail -n +2 "$tsv")

echo "file.tsv rows to verify: $row_count (skipped $skipped with an unexpected submitter_file_name, $missing_source with a missing/broken source file - logged straight to $missing_log)"
if [ "$row_count" -eq 0 ]; then
    echo "Nothing to verify."
    exit 0
fi

# Verifying still has to reach the S3 endpoint for every object's metadata,
# same as a transfer - only --checkers (comparison parallelism) applies
# here, there's nothing to upload. See upload_to_cqdg.sh for why this reads
# $SLURM_CPUS_PER_TASK.
if [ -n "${SLURM_CPUS_PER_TASK:-}" ]; then
    rclone_checkers=8
else
    echo "\$SLURM_CPUS_PER_TASK not set - running with minimal resource settings (interactive verification)"
    rclone_checkers=2
fi

size_only_flag=()
if [ "$size_only" -eq 1 ]; then
    size_only_flag=(--size-only)
    echo "(--size-only: comparing sizes only, not re-hashing every file)"
fi

echo "Verifying $row_count files: $source_dir <-> $dest_remote"
echo "rclone log: $check_log"

set +e
rclone check -L "$source_dir" "$dest_remote" \
    --files-from-raw "$filelist" \
    --checkers "$rclone_checkers" \
    --match "$confirmed_log" \
    --differ "$differs_log" \
    --missing-on-dst "$missing_log.tmp" \
    --error "$check_errors_log" \
    --log-file "$check_log" \
    --log-level INFO \
    "${size_only_flag[@]}"
set -e

# --missing-on-dst has to write to a fresh file, so append it to the
# missing_log that already holds this run's missing/broken source files
# rather than letting rclone overwrite them.
[ -f "$missing_log.tmp" ] && cat "$missing_log.tmp" >> "$missing_log" && rm -f "$missing_log.tmp"

confirmed_count=$(wc -l < "$confirmed_log" 2>/dev/null | tr -d ' '); confirmed_count=${confirmed_count:-0}
missing_count=$(wc -l < "$missing_log" 2>/dev/null | tr -d ' '); missing_count=${missing_count:-0}
differs_count=$(wc -l < "$differs_log" 2>/dev/null | tr -d ' '); differs_count=${differs_count:-0}
error_count=$(wc -l < "$check_errors_log" 2>/dev/null | tr -d ' '); error_count=${error_count:-0}

confirmed_size=$(awk -F'\t' -v prefix="${bucket_name}/" '
    NR==FNR { path=$0; sub("^"prefix,"",path); ok[path]=1; next }
    FNR==1 { next }
    { path=$4; sub(/^[A-Za-z0-9_-]+:\/\//,"",path); sub("^"prefix,"",path); if (path in ok) sum+=$5 }
    END { printf "%.2f", sum/1024/1024/1024/1024 }
' "$confirmed_log" "$tsv")
total_size=$(awk -F'\t' 'NR>1{sum+=$5} END{printf "%.2f", sum/1024/1024/1024/1024}' "$tsv")

echo "-----"
echo "Confirmed on remote (checksum match): $confirmed_count files, ${confirmed_size} TiB of ${total_size} TiB total"
echo "Still missing from remote: $missing_count"
echo "Present but checksum differs (needs re-send): $differs_count"
echo "Couldn't be checked (network/read error - inconclusive, retry): $error_count"

if [ "$differs_count" -gt 0 ] || [ "$missing_count" -gt 0 ]; then
    bam_incomplete=$(awk -F'\t' -v prefix="${bucket_name}/" '
        NR==FNR { path=$0; sub("^"prefix,"",path); incomplete[path]=1; next }
        FNR==1 { next }
        { path=$4; sub(/^[A-Za-z0-9_-]+:\/\//,"",path); sub("^"prefix,"",path); if (path in incomplete && $7=="BAM") count++ }
        END { print count+0 }
    ' <(cat "$missing_log" "$differs_log") "$tsv")
    echo "  of which BAM files: $bam_incomplete"
fi

echo
echo "Confirmed-transferred list (safe to skip next time, see upload_to_cqdg.sh -x): $confirmed_log"
echo "Missing: $missing_log"
echo "Differs: $differs_log"
echo "Check errors: $check_errors_log"

if [ "$missing_count" -gt 0 ] || [ "$differs_count" -gt 0 ] || [ "$error_count" -gt 0 ]; then
    exit 1
fi
exit 0
