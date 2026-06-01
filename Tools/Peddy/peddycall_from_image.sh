#!/bin/bash
#SBATCH --time=01:00:00
#SBATCH --account=def-rallard
#SBATCH --output=J-%x.%j.out
#SBATCH --cpus-per-task=1
#SBATCH --mem=3G
#Runs Peddy inside an apptainer image
#Arguments:
# $-i <familyID>
# $-p <proband_name>
# $-1 <parent_1_name>
# $-2 <parent_2_name>
# $-d <input_directory>

#It's not normally necessary to run in a sbatch, but for some reason,
#Running from images takes a long time for the pca step (same for Somalier)

set -eu
module load apptainer/1.3.5 python/3.11 htslib/1.22.1 bcftools/1.22 

echo "Arguments:"
for var in "$@"; do
 echo $var
done

usage() { echo "Usage: $0 [-i <familyID>] [-p <proband_name>] [-1 <parent_1_name>] [-2 <parent_2_name>] [-d <input_directory>]" 1>&2; exit 1; }
parent_2_name=""
while getopts ":p:1:2:i:d:" o; do
    case "${o}" in
        p)
            proband_name=${OPTARG}
            ;;
        1)
            parent_1_name=${OPTARG}
            ;;
        2)
            parent_2_name=${OPTARG}
            ;;
        i)
			family_id=${OPTARG}
			;;
        d)
            input_directory=${OPTARG}
            ;;
		*)
            usage
            ;;
    esac
done
if [ -z "${proband_name:-}" ] || [ -z "${parent_1_name:-}" ] || [ -z "${family_id:-}" ]; then
	usage
fi
here_folder=$(realpath $(dirname $0))

# Setup the images
if [ -z ${APPTAINER_CACHEDIR:-} ]; then
    echo """Warning: You should set an explicit directory for APPTAINER_CACHEDIR in ~/.bashrc IE:
    export APPTAINER_TMPDIR="~/scratch/singularity_cache/tmp"
    export APPTAINER_CACHEDIR="/home/felixant/scratch/singularity_cache"
"""
    echo "Using scratch folder as APPTAINER_CACHEDIR for now"
    export APPTAINER_CACHEDIR="$SCRATCH/apptainer_cache"
    mkdir -p "$APPTAINER_CACHEDIR"
fi
image="$APPTAINER_CACHEDIR/peddy_v0.4.8.sif"
if [ ! -f "$image" ]; then
	echo "Building Peddy apptainer image"
	apptainer build "$image" "$here_folder/peddy.def"
fi


ped_file="$input_directory/${family_id}.ped"

cd $input_directory

function index_vcf() {
	if [ -f "$1.$family_id.normed.joint.GRCh38.small_variants.phased.vcf.gz" ]; then
		if [ ! -f "$1.$family_id.normed.joint.GRCh38.small_variants.phased.vcf.gz.tbi" ]; then
			tabix -p vcf "$1.$family_id.normed.joint.GRCh38.small_variants.phased.vcf.gz"
		fi
	else
		echo "VCF file $1.$family_id.normed.joint.GRCh38.small_variants.phased.vcf.gz not found"
		exit 1
	fi
}

index_vcf "$proband_name"
index_vcf "$parent_1_name"
if [ "$parent_2_name" != "null" ] && [ "$parent_2_name" != "" ]; then
	index_vcf "$parent_2_name"
fi


here_folder=$(realpath $(dirname $0))

#We start with a normalized vcf separated for each individual, we just need to merge it again
if [ ! -f "$family_id.merged.normed.joint.GRCh38.small_variants.phased.vcf.gz" ]; then
		echo "Merging normed VCFs"
		if [ "$parent_2_name" != "null" ] && [ "$parent_2_name" != "" ]; then
			if [ ! -f "$parent_2_name.$family_id.normed.joint.GRCh38.small_variants.phased.vcf.gz.tbi" ]; then
				tabix -p vcf "$parent_2_name.$family_id.normed.joint.GRCh38.small_variants.phased.vcf.gz"
			fi 
			bcftools merge \
				"$proband_name.$family_id.normed.joint.GRCh38.small_variants.phased.vcf.gz" \
				"$parent_1_name.$family_id.normed.joint.GRCh38.small_variants.phased.vcf.gz" \
				"$parent_2_name.$family_id.normed.joint.GRCh38.small_variants.phased.vcf.gz" \
				-o "$family_id.merged.normed.joint.GRCh38.small_variants.phased.vcf.gz" -O z
		else #duo
			bcftools merge \
				"$proband_name.$family_id.normed.joint.GRCh38.small_variants.phased.vcf.gz" \
				"$parent_1_name.$family_id.normed.joint.GRCh38.small_variants.phased.vcf.gz" \
				-o "$family_id.merged.normed.joint.GRCh38.small_variants.phased.vcf.gz" -O z

		fi
		echo "Generating Index for merged normed VCFs"
		tabix -f -p vcf "$family_id.merged.normed.joint.GRCh38.small_variants.phased.vcf.gz"
	fi


mkdir -p "$input_directory/Peddy_analyses"
echo "Running Peddy relate"

apptainer exec -C -B $HOME -B $SCRATCH --pwd "$input_directory/Peddy_analyses" -W "$SLURM_TMPDIR" \
	$image \
	python -m peddy --plot --sites hg38 --prefix "${family_id}_peddy" \
	"$input_directory/$family_id.merged.normed.joint.GRCh38.small_variants.phased.vcf.gz" \
	"$ped_file"

echo "Peddy complete"