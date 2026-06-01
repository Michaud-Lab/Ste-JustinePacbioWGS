#!/bin/bash
#SBATCH --time=4:00:00
#SBATCH --account=def-rallard
#SBATCH --output=J-%x.%j.out
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G

#Runs Triomix inside an apptainer image
#Arguments:
# $1: Proband BAM file
# $2: Mother BAM file
# $3: Father line (either "null" if family is duo or "--father <fatherBAM>")
# $4: Fasta reference path
# $5: Output directory
set -euo pipefail
module load apptainer/1.3.5


echo "Arguments:"
for var in "$@"; do
 echo $var
done

usage() { echo "Usage: $0  [-p <proband bam>] [-m <mother bam>] [-f <father bam>] [-r <fasta reference>] [-o <Output Dir]" 1>&2; exit 1; }
father_line=""
while getopts ":p:m:f:r:o:" o; do
    case "${o}" in
        p)
            proband_bam=${OPTARG}
            ;;
        m)
            mother_bam=${OPTARG}
            ;;
        f)
            # Father is necessary for triomix, it does not work for duos
			father_bam=${OPTARG}
            ;;
        r)
            fasta_path=${OPTARG}
            ;;
        o)
            directory=${OPTARG}
            ;;
        *)
			echo "Received invalid option"
            usage
            ;;
    esac
done

if [ -z "${proband_bam:-}" ] || [ -z "${mother_bam:-}" ] || [ -z "${father_bam:-}" ] || [ -z "${fasta_path:-}" ] || [ -z "${directory:-}" ]; then
    usage
fi

image=$APPTAINER_CACHEDIR/triomix_v0.0.2.sif
if [ ! -f $image ];then
	echo "Downloading Triomix apptainer image"
	apptainer pull $image docker://cjyoon/triomix:v0.0.2
fi

cp $image $SLURM_TMPDIR

if [ ! -f $SLURM_TMPDIR/$proband_bam ]; then
	cp $proband_bam $SLURM_TMPDIR
	
fi
cp $proband_bam.bai $SLURM_TMPDIR
if [ ! -f $SLURM_TMPDIR/$mother_bam ]; then
  cp $mother_bam $SLURM_TMPDIR
  
fi
cp $mother_bam.bai $SLURM_TMPDIR
if [ ! -f $SLURM_TMPDIR/$fasta_path ]; then
  cp $fasta_path $SLURM_TMPDIR
  cp $fasta_path.fai $SLURM_TMPDIR
fi


if [ "$father_line" != "null" ]; then
	if [ ! -f $SLURM_TMPDIR/$father_bam ]; then
		cp $father_bam $SLURM_TMPDIR		
	fi
	cp $father_bam.bai $SLURM_TMPDIR
	father_line="--father $SLURM_TMPDIR/$(basename $father_bam)"
fi



# cat << EOF >$SLURM_TMPDIR/triomixScript.sh
mkdir -p $SLURM_TMPDIR/Triomix_analyses
echo "apptainer exec -C -W $SLURM_TMPDIR -B $SLURM_TMPDIR -B $HOME \
	$SLURM_TMPDIR/$(basename $image)"
apptainer exec -C -W $SLURM_TMPDIR -B $SLURM_TMPDIR -B $HOME \
	$SLURM_TMPDIR/$(basename $image) \
	python3 /tools/triomix/triomix.py \
	--father $SLURM_TMPDIR/$(basename $father_bam) \
	--mother $SLURM_TMPDIR/$(basename $mother_bam) \
	--child $SLURM_TMPDIR/$(basename $proband_bam) \
	--reference $SLURM_TMPDIR/$(basename $fasta_path) \
	--parent \
	--thread 8 \
	--snp "/tools/triomix/common_snp/grch38_common_snp.bed.gz" \
	--output_dir $SLURM_TMPDIR/Triomix_analyses

mkdir -p $directory/Triomix_analyses
cp -r $SLURM_TMPDIR/Triomix_analyses/* $directory/Triomix_analyses/