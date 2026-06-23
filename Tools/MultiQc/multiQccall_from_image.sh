#!/bin/bash
#SBATCH --job-name=multiqc_${family_id}
#SBATCH --output=J-%x.%j.out
#SBATCH --account=def-rallard
#SBATCH --mem=4G
#SBATCH --time=01:00:00

module load apptainer/1.3.5

log_file=""
while getopts ":l:" opt; do
    case "${opt}" in
        l)  log_file="${OPTARG}" ;;
        *)  ;;
    esac
done

log_step() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; [ -n "${log_file:-}" ] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$log_file"; }
trap 'rc=$?; [ $rc -ne 0 ] && [ -n "${log_file:-}" ] && echo "[$(date +%Y-%m-%dT%H:%M:%S)] FAILED: multiqc (rc=$rc)" >> "$log_file"' EXIT

apptainer exec -W $SLURM_TMPDIR -B $SCRATCH \
	$APPTAINER_CACHEDIR/multiqc_v1.3.3.sif  \
	multiqc .

log_step "SUCCESS: multiqc"
