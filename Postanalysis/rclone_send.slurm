#!/bin/bash
#SBATCH --job-name=rclone_send
#SBATCH --output=J-%x.%j.out
#SBATCH --account=def-rallard
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=20G

# Copies a local directory to an rclone remote, following symlinks (-L).
# Tuned for large files (~70 GB) to a Ceph S3 backend:
#   --transfers 2            : 2 files uploaded in parallel (large files — more would exhaust memory)
#   --s3-chunk-size 512M     : multipart part size; fewer API round-trips for large files
#   --s3-upload-concurrency 8: parallel chunk uploads per file (uses ~4 GB RAM per file transfer)
#   --buffer-size 512M       : read-ahead buffer per transfer
# Peak RAM: 2 files × (8 chunks × 512 MB + 512 MB buffer) ≈ 9 GB → 20 G requested with headroom
#
# Usage: sbatch rclone_send.slurm -s <source_dir> -d <destination> [-l <log_file>]
#   -s  Source directory (local path, symlinks will be followed)
#   -d  Rclone destination (e.g. decodeur-pacbio:decodeur-pacbio/S3-Storage/p136)
#   -l  Optional shared log file for FAILED/SUCCESS status

set -eo pipefail

usage() { echo "Usage: $0 -s <source_dir> -d <destination> [-l <log_file>]" 1>&2; exit 1; }
log_file=""
while getopts ":s:d:l:" opt; do
    case "${opt}" in
        s)  source_dir="${OPTARG}" ;;
        d)  destination="${OPTARG}" ;;
        l)  log_file="${OPTARG}" ;;
        :)  echo "Error: -${OPTARG} requires an argument."; usage ;;
        *)  usage ;;
    esac
done
log_step() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; [ -n "${log_file:-}" ] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$log_file"; }
trap 'rc=$?; [ $rc -ne 0 ] && [ -n "${log_file:-}" ] && echo "[$(date +%Y-%m-%dT%H:%M:%S)] FAILED: rclone_send to ${destination:-?} (rc=$rc)" >> "$log_file"' EXIT

if [ -z "${source_dir:-}" ] || [ -z "${destination:-}" ]; then
    echo "Error: -s and -d are required."
    usage
fi

echo "Copying $source_dir → $destination"
rclone copy -L \
    --transfers 2 \
    --s3-chunk-size 512M \
    --s3-upload-concurrency 8 \
    --multi-thread-streams 16 \
    --buffer-size 512M \
    "$source_dir" "$destination"
log_step "SUCCESS: rclone_send to $destination"
