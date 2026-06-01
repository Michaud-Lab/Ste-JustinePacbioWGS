#!/bin/bash
#SBATCH --job-name=multiqc_${family_id}
#SBATCH --output=J-%x.%j.out
#SBATCH --account=def-rallard
#SBATCH --mem=4G
#SBATCH --time=01:00:00

module load apptainer/1.3.5
apptainer exec -W $SLURM_TMPDIR -B $SCRATCH \
	$APPTAINER_CACHEDIR/multiqc_v1.3.3.sif  \
	multiqc .