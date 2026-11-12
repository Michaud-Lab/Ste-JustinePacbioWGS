#!/bin/bash
#
# Uploads every file listed in file.tsv (the submitter_file_name column) to
# the CQDG staging bucket via rclone. submitter_file_name looks like
# "cqdg-staging://chusj-decodeur-staging-sd4h/<relpath>" - <relpath> is both
# the path under the local CQDG_Deliverables symlink tree (source) and the
# key under the destination bucket (destination), so one `rclone copy
# --files-from-raw` transfers everything file.tsv lists.
#
# Meant to run as a long Slurm job (see cqdg_upload.slurm) since some BAMs
# are 70+ GB and there are thousands of rows. Safe to re-run/resubmit after a
# timeout or partial failure: rclone skips files already present at the
# destination with a matching checksum, so only what's missing or failed
# gets retried.
#
# The CQDG working directory (where file.tsv lives and logs/ get written) is
# read from a config file's Paths.WGS_folder, not derived from this script's
# own location - dirname "$0" is unreliable under Slurm (sbatch runs a spool
# copy of the script, not the original file).
#
# Usage: upload_to_cqdg.sh [-c config_file] [-t file.tsv] [-s source_dir] [-d dest_remote] [-l log_dir] [-x exclude_file] [-n]
#   -c  Path to the WGS config JSON (default: $WGS_CONFIG_FILE)
#   -t  Path to file.tsv (default: file.tsv under Paths.WGS_folder/CQDG)
#   -s  Local source dir that submitter_file_name paths are relative to
#       (default: the CQDG_Deliverables dir generate_file_tsv.sh reads from)
#   -d  Rclone destination remote:bucket (default: cqdg-staging:chusj-decodeur-staging-sd4h)
#   -l  Directory to write logs into (default: logs/ under Paths.WGS_folder/CQDG)
#   -x  File of relpaths (one per line, e.g. a confirmed_*.log from
#       verify_cqdg_transfer.sh) to skip outright - saves rclone from having
#       to re-checksum files already verified as correctly on the remote
#   -n  Dry run - report what would be transferred without copying anything

set -euo pipefail

config_file="${WGS_CONFIG_FILE:-}"
tsv=""
source_dir="/home/felixant/projects/ctb-rallard/COMMUN/PacBioData/CQDG_Deliverables"
dest_remote="cqdg-staging:chusj-decodeur-staging-sd4h"
log_dir=""
exclude_file=""
dry_run=0

usage() { echo "Usage: $0 [-c config_file] [-t file.tsv] [-s source_dir] [-d dest_remote] [-l log_dir] [-x exclude_file] [-n]" 1>&2; exit 1; }

while getopts ":c:t:s:d:l:x:n" opt; do
    case "${opt}" in
        c) config_file="${OPTARG}" ;;
        t) tsv="${OPTARG}" ;;
        s) source_dir="${OPTARG}" ;;
        d) dest_remote="${OPTARG}" ;;
        l) log_dir="${OPTARG}" ;;
        x) exclude_file="${OPTARG}" ;;
        n) dry_run=1 ;;
        :) echo "Error: -${OPTARG} requires an argument." 1>&2; usage ;;
        *) usage ;;
    esac
done

if [ -n "$exclude_file" ]; then
    [ -f "$exclude_file" ] || { echo "Error: exclude file not found: $exclude_file" 1>&2; exit 1; }
fi

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
rclone_log="$log_dir/rclone_${timestamp}.log"
success_log="$log_dir/transferred_${timestamp}.log"
error_log="$log_dir/errors_${timestamp}.log"
filelist="$(mktemp)"
trap 'rm -f "$filelist"' EXIT

# Bucket name is derived from $dest_remote (part after the first ":") so the
# prefix check below still works if -d overrides the default remote/bucket.
bucket_name="${dest_remote#*:}"
prefix_regex="^[A-Za-z0-9_-]+://${bucket_name}/"

declare -A exclude_set
if [ -n "$exclude_file" ]; then
    while IFS= read -r relpath; do
        [ -n "$relpath" ] && exclude_set["$relpath"]=1
    done < "$exclude_file"
fi

row_count=0
skipped=0
missing=0
excluded=0
: > "$filelist"
while IFS=$'\t' read -r -a fields; do
    submitter_file_name="${fields[3]:-}"
    [ -z "$submitter_file_name" ] && continue
    if [[ "$submitter_file_name" =~ $prefix_regex ]]; then
        relpath="${submitter_file_name#*://*/}"
        if [ -n "${exclude_set[$relpath]:-}" ]; then
            excluded=$((excluded + 1))
            continue
        fi
        # rclone's --files-from-raw silently drops entries that don't exist
        # under $source_dir instead of erroring, so a missing/broken symlink
        # would otherwise vanish without ever reaching the error log.
        if [ ! -e "$source_dir/$relpath" ]; then
            echo "$(date +'%Y/%m/%d %H:%M:%S') ERROR : $relpath: source file missing or unreadable ($source_dir/$relpath)" >> "$error_log"
            missing=$((missing + 1))
            continue
        fi
        printf '%s\n' "$relpath" >> "$filelist"
        row_count=$((row_count + 1))
    else
        echo "WARNING: submitter_file_name doesn't match expected 'scheme://${bucket_name}/...' format, skipped: $submitter_file_name" | tee -a "$error_log" 1>&2
        skipped=$((skipped + 1))
    fi
done < <(tail -n +2 "$tsv")

echo "file.tsv rows to transfer: $row_count (skipped $skipped with an unexpected submitter_file_name, $missing with a missing/broken source file, $excluded excluded via -x)"
if [ "$row_count" -eq 0 ]; then
    echo "Nothing to transfer."
    if [ "$missing" -gt 0 ]; then
        echo "See $error_log for missing source files."
        exit 1
    fi
    exit 0
fi

dry_run_flag=()
[ "$dry_run" -eq 1 ] && dry_run_flag=(--dry-run)

# Compute nodes don't always have internet access, so this sometimes has to
# run interactively on a login/data-transfer node instead of through sbatch
# (cqdg_upload.slurm requests --cpus-per-task=8, which is what the "tuned"
# numbers below assume). $SLURM_CPUS_PER_TASK being unset is how we tell
# we're in that interactive case, where resources are shared and limited -
# so keep rclone's parallelism and memory use minimal.
if [ -n "${SLURM_CPUS_PER_TASK:-}" ]; then
    rclone_transfers=2
    rclone_checkers=8
    rclone_chunk_size=512M
    rclone_upload_concurrency=8
    rclone_buffer_size=512M
else
    echo "\$SLURM_CPUS_PER_TASK not set - running with minimal resource settings (interactive transfer)"
    rclone_transfers=1
    rclone_checkers=2
    rclone_chunk_size=256M
    rclone_upload_concurrency=2
    rclone_buffer_size=64M
fi

echo "Transferring $row_count files: $source_dir -> $dest_remote"
[ "$dry_run" -eq 1 ] && echo "(dry run - no data will be copied)"
echo "rclone log: $rclone_log"

set +e
rclone copy -L \
    --files-from-raw "$filelist" \
    --transfers "$rclone_transfers" \
    --checkers "$rclone_checkers" \
    --s3-chunk-size "$rclone_chunk_size" \
    --s3-upload-concurrency "$rclone_upload_concurrency" \
    --buffer-size "$rclone_buffer_size" \
    --checksum \
    --retries 3 \
    --low-level-retries 10 \
    --log-file "$rclone_log" \
    --log-level INFO \
    "${dry_run_flag[@]}" \
    "$source_dir" "$dest_remote"
rclone_rc=$?
set -e

# INFO "Copied (...)" covers real transfers; the NOTICE "Skipped copy as
# --dry-run is set" line is rclone's dry-run equivalent (-n never logs
# "Copied"). Already-up-to-date files aren't logged at all at INFO level, so
# a resumed run's success_log only lists what it actually transferred.
grep -E '(INFO|NOTICE) *: .*(Copied \(|Skipped copy as --dry-run)' "$rclone_log" > "$success_log" || true
grep -E 'ERROR *: ' "$rclone_log" >> "$error_log" || true

success_count=$(wc -l < "$success_log" | tr -d ' ')
error_count=$(grep -c -E 'ERROR *: ' "$error_log") || true

echo "-----"
echo "Transferred/skipped (already up to date): $success_count"
echo "Errors: $error_count"

if [ "$error_count" -gt 0 ]; then
    # Cross-reference failed paths against file.tsv's file_type column so BAM
    # failures (the files most worth flagging - large, slow, likely to hit a
    # network hiccup) stand out instead of scrolling by in the general log.
    bam_errors=$(awk -F'\t' -v prefix="${bucket_name}/" '
        NR==FNR {
            if (FNR==1) next
            path=$4; sub(/^[A-Za-z0-9_-]+:\/\//,"",path); sub("^"prefix,"",path)
            type[path]=$7
            next
        }
        {
            line=$0
            sub(/^.*ERROR *: /,"",line)
            sub(/: .*$/,"",line)
            if (line in type && type[line]=="BAM") count++
        }
        END { print count+0 }
    ' "$tsv" "$error_log")
    echo "  of which BAM files: $bam_errors"
    echo "See $error_log for details."
fi

echo "Successful transfers logged to: $success_log"
echo "Errors logged to: $error_log"

# Missing source files never reach rclone, so they wouldn't otherwise affect
# rclone_rc even though they belong in file.tsv and didn't get uploaded.
[ "$rclone_rc" -eq 0 ] && [ "$error_count" -gt 0 ] && rclone_rc=1
exit "$rclone_rc"
