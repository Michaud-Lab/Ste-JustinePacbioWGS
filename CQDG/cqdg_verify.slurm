#!/bin/bash
#SBATCH --job-name=cqdg_verify
#SBATCH --output=J-%x.%j.out
#SBATCH --account=def-rallard
#SBATCH --time=7-00:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=8G

# Long-running Slurm job that confirms every file listed in file.tsv is
# actually on the CQDG staging bucket with a matching checksum (see
# verify_cqdg_transfer.sh - this is just the sbatch wrapper). Has to re-read
# and re-hash every local file, so for ~9 TB it can take a long time in its
# own right.
#
# The CQDG directory (where verify_cqdg_transfer.sh lives) is read from a
# config file's Paths.WGS_folder rather than dirname "$0" - sbatch runs a
# spool copy of this script, not the original file, so dirname "$0" isn't
# reliable here.
#
# Usage:
#   sbatch cqdg_verify.slurm                    # full checksum verify, $WGS_CONFIG_FILE must be set
#   sbatch cqdg_verify.slurm -c my_conf.json     # explicit config file
#   sbatch cqdg_verify.slurm --size-only         # fast, sizes only
# Any other verify_cqdg_transfer.sh flag (-t/-s/-d/-l) can be passed through too.

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

"$wgs_folder/CQDG/verify_cqdg_transfer.sh" "$@"
