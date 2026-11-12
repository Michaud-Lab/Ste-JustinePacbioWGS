#!/bin/bash
#SBATCH --job-name=cqdg_upload
#SBATCH --output=J-%x.%j.out
#SBATCH --account=def-rallard
#SBATCH --time=7-00:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=24G

# Long-running Slurm job that uploads every file listed in file.tsv to the
# CQDG staging bucket (see upload_to_cqdg.sh - this is just the sbatch
# wrapper). 7-00:00:00 is the cluster's max regular walltime; the underlying
# transfer is resumable, so if it still isn't enough, just resubmit and
# rclone will skip everything already uploaded correctly.
#
# The CQDG directory (where upload_to_cqdg.sh lives) is read from a config
# file's Paths.WGS_folder rather than dirname "$0" - sbatch runs a spool copy
# of this script, not the original file, so dirname "$0" isn't reliable here.
#
# Usage:
#   sbatch cqdg_upload.slurm                    # real transfer, $WGS_CONFIG_FILE must be set
#   sbatch cqdg_upload.slurm -c my_conf.json     # real transfer, explicit config file
#   sbatch cqdg_upload.slurm -n                  # dry run only
# Any other upload_to_cqdg.sh flag (-t/-s/-d/-l) can be passed through too.

set -eo pipefail

config_file="${WGS_CONFIG_FILE:-}"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [ "${args[i]}" = "-c" ] && [ $((i + 1)) -lt ${#args[@]} ]; then
        config_file="${args[i + 1]}"
    fi
done

if [ -z "$config_file" ]; then
    echo "Error: no config file given - set \$WGS_CONFIG_FILE or pass -c <config_file>." 1>&2
    exit 1
fi
[ -f "$config_file" ] || { echo "Error: config file not found: $config_file" 1>&2; exit 1; }

wgs_folder="$(jq -r '.Paths.WGS_folder // empty' "$config_file")"
[ -n "$wgs_folder" ] || { echo "Error: Paths.WGS_folder not set in config file: $config_file" 1>&2; exit 1; }

"$wgs_folder/CQDG/upload_to_cqdg.sh" "$@"
