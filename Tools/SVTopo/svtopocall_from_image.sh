#!/bin/bash
#SBATCH --time=8:00:00
#SBATCH --account=def-rallard
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --output=J-%x.%j.out
#SBATCH --mem=8G

#Runs SVTOPO and svtopovz inside an apptainer image
#Arguments:
# $1: Prefix for output files
# $2: Haplotagged BAM file
# $3: BAM index file
# $4: Supporting reads JSON file
# $5: VCF file with structural variants
# $6: Output directory
# $7: Resource folder (with gff3 and excluded regions bed)
# $8: Script folder (to have access to the Tools folder even in sbatch)

set -eu
module load apptainer/1.3.5
projects=$HOME/projects


echo "Arguments:"
for var in "$@"; do
 echo $var
done

usage() { echo "Usage: $0  [-p <prefix>] [-b <haplotagged bam>] [-i <haplotagged bam index>] [-s <supporting reads>] [-v <SV vcf>] [-r <resource folder>] [-o <Output Dir>] [-t <tools folder>]" 1>&2; exit 1; }

log_file=""
while getopts ":p:b:i:r:v:o:s:t:l:" o; do
    case "${o}" in
        p)
            echo "prefix: ${OPTARG}"
            prefix=${OPTARG}
            prefix=${prefix%%_*} #Prefix cannot contain underscores
            echo "prefix after removing underscores: ${prefix}"
            ;;
        b)
            haplotagged_bam=${OPTARG}
            ;;
        i)
            haplotagged_bam_index=${OPTARG}
      			;;
		    s)
            supporting_reads=${OPTARG}
            ;;
        v)
            vcf=${OPTARG}
            ;;
	      r)
            resource_folder=${OPTARG}
            ;;
        o)
            outputDir=${OPTARG}
            ;;
        t)
            tools_folder=${OPTARG}
            ;;
        l)
            log_file=${OPTARG}
            ;;
	      *)
            echo "Received invalid option"
            usage
            ;;
    esac
done
log_step() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; [ -n "${log_file:-}" ] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$log_file"; }
trap 'rc=$?; [ $rc -ne 0 ] && [ -n "${log_file:-}" ] && echo "[$(date +%Y-%m-%dT%H:%M:%S)] FAILED: svtopo for ${prefix:-?} (rc=$rc)" >> "$log_file"' EXIT

if [ -z "${prefix:-}" ] || [ -z "${haplotagged_bam:-}" ] || [ -z "${haplotagged_bam_index:-}" ] || [ -z "${supporting_reads:-}" ] || [ -z "${vcf:-}" ] || [ -z "${resource_folder:-}" ]; then
	usage
fi

cp "$haplotagged_bam" "$SLURM_TMPDIR"
bam="$(basename $haplotagged_bam)"
cp "$haplotagged_bam_index" "$SLURM_TMPDIR"
cp "$supporting_reads" "$SLURM_TMPDIR"
supporting_reads="$(basename $supporting_reads)"
cp "$vcf" "$SLURM_TMPDIR"
vcf="$(basename $vcf)"

# #This is a home-made image, not hosted on dockerhub for now
image=$APPTAINER_CACHEDIR/svtopo_v0.3.0.sif
if [ ! -f $image ]; then
  echo "Building SVTopo apptainer image"
  apptainer build $image $tools_folder/SVTopo/svtopo.def
fi

cp $resource_folder/GRCh38/ensembl.GRCh38.101.reformatted.gff3.gz "$SLURM_TMPDIR"
cp $tools_folder/SVTopo/repeatmaskerUCSC.bed.gz "$SLURM_TMPDIR"
cp $resource_folder/cnv.excluded_regions.hg38.bed.gz "$SLURM_TMPDIR"
cp $image $SLURM_TMPDIR
#As suggested in https://github.com/PacificBiosciences/SVTopo/blob/main/docs/user_guide.md for annotation
zgrep -iE "L1|L2|LINE|SVA" $SLURM_TMPDIR/repeatmaskerUCSC.bed.gz \
    | awk '($3 - $2) >= 2000 { print $1, $2, $3, $4, $6 }' > $SLURM_TMPDIR/retrotransposons.bed

#Temporary script to run inside apptainer
cat << EOF > $SLURM_TMPDIR/svtopo_apptainer_script.sh
#!/bin/bash
set -eu

mkdir -p "SVTOPO_OUTPUTS/${prefix}_svtopo"

svtopo \
  --bam "$bam" \
  --variant-readnames "$supporting_reads" \
  --vcf "$vcf" \
  --svtopo-dir "SVTOPO_OUTPUTS/${prefix}_svtopo" \
  --exclude-regions "/app/SVTopo/cnv.excluded_regions.hg38.bed.gz"\
  --prefix "${prefix}"

svtopovz \
  --svtopo-dir "SVTOPO_OUTPUTS/${prefix}_svtopo" \
  --genes "ensembl.GRCh38.101.reformatted.gff3.gz" \
  --annotation-bed "repeatmaskerUCSC.bed.gz" "retrotransposons.bed" \
  --verbose
EOF
cat $SLURM_TMPDIR/svtopo_apptainer_script.sh
echo "----"
ls $SLURM_TMPDIR
echo "----"
chmod +x $SLURM_TMPDIR/svtopo_apptainer_script.sh

mkdir -p $SLURM_TMPDIR/SVTOPO_OUTPUTS
apptainer exec -C -W $SLURM_TMPDIR -B $HOME -B $SLURM_TMPDIR \
  --pwd $SLURM_TMPDIR $SLURM_TMPDIR/$(basename $image) /bin/bash \
  $SLURM_TMPDIR/svtopo_apptainer_script.sh

mkdir -p "$outputDir/SVTOPO_OUTPUTS/${prefix}_svtopo"
cp -rv $SLURM_TMPDIR/SVTOPO_OUTPUTS/${prefix}_svtopo $outputDir/SVTOPO_OUTPUTS
log_step "SUCCESS: svtopo for ${prefix}"