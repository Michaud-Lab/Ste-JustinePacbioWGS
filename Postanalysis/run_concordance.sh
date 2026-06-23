#!/bin/bash
#SBATCH --job-name=concordance
#SBATCH --output=J-%x.%j.out
#SBATCH --account=def-rallard
#SBATCH --mem=8G
#SBATCH --time=02:00:00

# Runs SR/LR VCF concordance for a single sample.
# Fetches the Illumina GVCF from the staging server via rclone, then calls
# sr-lr_vcf_concordance.py with the PacBio normalized SNV VCF and the GVCF.
#
# Usage: run_concordance.sh -n <sample_name> -v <lr_snv_vcf> -o <output_dir> [-h <here_folder>] [-c <config_file>]
#   -n  Sample name (used to locate the GVCF on staging_juno)
#   -v  Path to the PacBio normalized SNV VCF (from postprocessPart1.sh)
#   -o  Output directory (a Concordance/ subdirectory will be created inside it)

set -eo pipefail
module load bcftools gatk/4.6.1.0 python/3.11
REMOTE_BASE_PREFIX="staging_juno:/pragmatiq-staging-sd4h/data"

usage() {
    echo "Usage: $0 -n <sample_name> -v <lr_snv_vcf> -o <output_dir> -t <tools_folder> [-c <config_file>]"
    1>&2; exit 1
}

here_folder="$(cd "$(dirname "$0")" && pwd)"
tools_folder="$here_folder/../Tools"
sample_name=""
lr_vcf=""
output_dir=""
fasta="$SCRATCH/GATK_references/Homo_sapiens_assembly38.fasta"
log_file=""
while getopts ":n:v:o:f:t:l:" opt; do
    case "${opt}" in
        n)  sample_name="${OPTARG}" ;;
        v)  lr_vcf="${OPTARG}" ;;
        o)  output_dir="${OPTARG}" ;;
        f)  fasta="${OPTARG}" ;; # Note that this fasta requires a dict to run GATK commands
        t)  tools_folder="${OPTARG}"
            here_folder="$tools_folder/../Postanalysis/"
            ;;
        l)  log_file="${OPTARG}" ;;
        :)  echo "Error: -${OPTARG} requires an argument."; usage ;;
        *)  usage ;;
    esac
done
log_step() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; [ -n "${log_file:-}" ] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$log_file"; }
trap 'rc=$?; [ $rc -ne 0 ] && [ -n "${log_file:-}" ] && echo "[$(date +%Y-%m-%dT%H:%M:%S)] FAILED: concordance for ${sample_name:-?} (rc=$rc)" >> "$log_file"' EXIT

if [ -z "$sample_name" ] || [ -z "$lr_vcf" ] || [ -z "$output_dir" ]; then
    echo "Error: -n, -v, and -o are required."
    usage
fi

if [ ! -f "$lr_vcf" ]; then
    echo "Error: LR SNV VCF not found: $lr_vcf"
    exit 1
fi

if [ ! -f "$fasta" ]; then
    echo "Error: Fasta ref not found: $lr_vcf"
    exit 1
fi

concordance_dir="$output_dir/Concordance"
mkdir -p "$concordance_dir"

report_file="$concordance_dir/concordance_report_${sample_name}.txt"
remote_dir="${REMOTE_BASE_PREFIX}/${sample_name}"
sr_gvcf_name="${sample_name}.dragen.hard-filtered.gvcf.gz"
sr_vcf="$concordance_dir/${sample_name}.dragen.hard-filtered.vcf.gz"

if [ ! -f "$concordance_dir/$sr_gvcf_name" ] && [ ! -f $sr_vcf ]; then
    # ── Locate GVCF on staging server ────────────────────────────────────────────
    echo "Searching for ${sr_gvcf_name} on ${remote_dir} with command:"
    cat << EOF 
rclone lsf --format "tp" --files-only -R --include "$sr_gvcf_name" "$remote_dir"
EOF
    remote_listing=$(rclone lsf --format "tp" --files-only -R --include "$sr_gvcf_name" "$remote_dir" 2>/dev/null || true)

    if [ -z "$remote_listing" ]; then
        echo "WARNING: ${sr_gvcf_name} not found on staging_juno for sample ${sample_name}. Skipping concordance."
        exit 0
    else echo "Found these results:" ; echo "$remote_listing"
    fi

    result_count=$(echo "$remote_listing" | wc -l)
    if [ "$result_count" -gt 1 ]; then
        echo "Found ${result_count} matches for ${sr_gvcf_name} — selecting the most recent."
    fi
    # Each line is "YYYY-MM-DD HH:MM:SS path"; reverse-sort picks the most recent, awk extracts the path
    remote_result=$(echo "$remote_listing" | sort -r | head -1 | awk -F';' '{print $NF}')
        
    # ── Download GVCF (and index if available) ───────────────────────────────────
    echo "Found: ${remote_result} — downloading to ${concordance_dir}/ with command:"
    cat << EOF
rclone copy "${remote_dir}/${remote_result}"      "$concordance_dir/"
EOF
    rclone copy "${remote_dir}/${remote_result}"      "$concordance_dir/"
    rclone copy "${remote_dir}/${remote_result}.tbi"  "$concordance_dir/" 2>/dev/null || true

    sr_gvcf="${concordance_dir}/${sr_gvcf_name}"

    if [ ! -f "$sr_gvcf" ]; then
        echo "ERROR: Download of ${sr_gvcf_name} failed."
        exit 1
    fi

else echo "skipping download"
fi
sr_gvcf="${concordance_dir}/${sr_gvcf_name}"
# Index locally if the remote .tbi was absent
if [ ! -f "${sr_gvcf}.tbi" ]; then
    echo "Indexing ${sr_gvcf_name}..."
    gatk IndexFeatureFile -I "$sr_gvcf"
fi
if [ ! -f $sr_vcf ]; then
    gatk GenotypeGVCFs  \
        --variant "$sr_gvcf" \
        --output "$sr_vcf" \
        --QUIET true \
        --reference "$fasta"
    echo "Gatk Genotype done for sr_gvcf"
    rm "$sr_gvcf"
fi
#------Set up virtual env ------#
ENVDIR=$tools_folder/ENV
if [ -d "$ENVDIR" ]; then
    echo "Activating Venv"
	source $ENVDIR/bin/activate
else
	virtualenv --no-download $ENVDIR
	source $ENVDIR/bin/activate
	pip install --no-index --upgrade pip
	pip install -r "$tools_folder/requirements.txt"
fi

if [ ! -f "${report_file}" ]; then
    # ── Run concordance ───────────────────────────────────────────────────────────
    echo "Running SR/LR concordance for ${sample_name} with command:"
    cat << EOF
python3 "${here_folder}/sr-lr_vcf_concordance.py" \
    --vcf1 "$lr_vcf" \
    --vcf2 "$sr_vcf" \
    --output "$report_file"
EOF
    python3 "${here_folder}/sr-lr_vcf_concordance.py" \
        --vcf1 "$lr_vcf" \
        --vcf2 "$sr_vcf" \
        --output "$report_file"

    echo "Concordance report written to: ${report_file}"
fi





# Backup report with intervals:
deactivate
interval="$SCRATCH/SNPs44.bed"
lr_select_vcf=$concordance_dir/$(basename "$lr_vcf" .vcf.gz).select.vcf.gz
#Long Read Region selection
if [ ! -f $lr_select_vcf ]; then
    gatk SelectVariants  \
        --variant "$lr_vcf" \
        --output "$lr_select_vcf" \
        --QUIET true \
        --create-output-variant-index false \
        --intervals "$interval"
    echo "Gatk select done for lrGVCF"
    gatk IndexFeatureFile \
        -I "$lr_select_vcf"
fi

sr_select_vcf=$concordance_dir/$(basename "$sr_gvcf_name" .gvcf.gz).select.vcf.gz
if [ ! -f $sr_select_vcf ]; then
    gatk SelectVariants  \
        --variant "$sr_vcf" \
        --output "$sr_select_vcf" \
        --QUIET true \
        --create-output-variant-index false \
        --intervals "$interval"
    echo "Gatk select done for lrGVCF"
    gatk IndexFeatureFile \
        -I "$sr_select_vcf"
fi

isec_report_dir="$concordance_dir/Isec"
bcftools isec  \
    -p "$isec_report_dir" \
    "$sr_select_vcf" \
    "$lr_select_vcf"
echo "bcftools isec done"

numMismatch=0
mismatchList=""
# "10" means the variant is present only in the short read VCF, "01" means only in the long read VCF.
while IFS=$'\t' read -r col1 col2 col3 col4 col5; do
		if [[ "$col5" == "10" || "$col5" == "01" ]]; then
			mismatchList="${mismatchList}${col1}\t${col2}\t${col3}\t${col4}\t${col5}\n"
			numMismatch=$((numMismatch + 1))
		fi
	done < "$isec_report_dir/sites.txt"


siteFile=$isec_report_dir/sites.txt
echo "Report for $sample_name" >"${isec_report_dir}/${sample_name}_summary.txt"
uniqList=$(cut "$siteFile" -f 1-2 | uniq -c)
numVar=$(echo "$uniqList" | wc -l)

echo "Num of Non-Ref variants among 44 positions:$numVar" >>"${isec_report_dir}/${sample_name}_summary.txt"
echo "Num of variants of same position not matching :$numMismatch" >>"${isec_report_dir}/${sample_name}_summary.txt"


if [ $numMismatch -eq 0 ]; then
    echo "$sample_name: No mismatches found between long and short reads for the 44 SNPs"
    echo "See report at $isec_report_dir"
    printf "No mismatched genotypes to report\n" >"${isec_report_dir}/${sample_name}_report.txt"
else
    echo "$sample_name: $numMismatch mismatches found between long and short reads for the 44 SNPs"
    echo "See report at $isec_report_dir"
    printf "$sample_name Mismatch list: \n$mismatchList\n" >"${isec_report_dir}/${sample_name}_report.txt"

fi


if [ -z "$2" ]; then
    echo "I will now delete the intermediate VCF files, specify 'k' to keep them"
    rm -f "$lr_select_vcf"* "$sr_select_vcf"*
    
elif [ "$2" == 'k' ]; then
    echo "Keeping intermediate VCF files as per your request"
fi
log_step "SUCCESS: concordance for ${sample_name}"