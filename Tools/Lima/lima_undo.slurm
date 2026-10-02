#!/bin/bash
#
#SBATCH --time=16:00:00
#SBATCH --output=J-%x.%j.out
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --tmp=200G

# Runs lima-undo (from the PacBio lima apptainer image) to undo lima's original barcode
# assignment for both the hifi_reads and fail_reads BAMs of a well, then chains into
# lima_redo.slurm to re-run lima and remultiplex both read types.
#
# Arguments:
# -x <MOVIE.bcXXXX.consensusreadset.xml>  (full absolute path)
# -c <config_file> (optional, defaults to $WGS_CONFIG_FILE)
# -l <log_file> (optional; overall job log to append SUCCESS/FAILED lines to)
#
# The hifi_reads/fail_reads "unassigned" BAMs staged on $SLURM_TMPDIR here can be 100GB+,
# and node-local disk is a shared pool unless reserved - the --tmp=100G above is only a
# floor for standalone runs; run_lima-remultiplex.sh overrides it per-cell with
# `sbatch --tmp=...` sized from the actual BAM being processed.
#
#example call:
#sbatch -D /home/felixant/links/projects/rrg-rallard/shared/PacBioDataRorqual/SequencerData/r84196_20251010_130733/1_B01/pb_formats lima_undo.slurm -x /home/felixant/links/projects/rrg-rallard/shared/PacBioDataRorqual/SequencerData/r84196_20251010_130733/1_B01/pb_formats/m84196_251010_201413_s3.hifi_reads.bc2090.consensusreadset.xml

set -exo pipefail
module load apptainer/1.3.5

usage() { echo "Usage: sbatch lima_undo.slurm -x /full/path/to/MOVIE.bcXXXX.consensusreadset.xml [-c <config_file>] [-l <log_file>]" 1>&2; exit 1; }

config_file=""
log_file=""
while getopts "x:c:l:" opt; do
	case "${opt}" in
		x) inputxml=${OPTARG} ;;
		c) config_file=${OPTARG} ;;
		l) log_file=${OPTARG} ;;
		*) usage ;;
	esac
done

if [ -z "${inputxml:-}" ]; then
	usage
fi
: "${SLURM_TMPDIR:?SLURM_TMPDIR is not set - this script must run inside a Slurm job}"
log_step() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; [ -n "${log_file:-}" ] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$log_file"; }
trap 'rc=$?; [ $rc -ne 0 ] && [ -n "${log_file:-}" ] && echo "[$(date +%Y-%m-%dT%H:%M:%S)] FAILED: lima-undo for ${inputxml:-?} (rc=$rc)" >> "$log_file"' EXIT

# lima_redo.slurm reads its input BAMs straight off Lustre (no local staging) but writes its
# split-per-barcode output to $SLURM_TMPDIR, whose total volume is roughly the sum of both
# corrected BAMs - size its --tmp reservation from the actual BAMs instead of a fixed guess.
submit_lima_redo() {
	local xml="$1"; shift
	local redo_tmp_mb=2048 bytes bam
	for bam in "$@"; do
		bytes=$(stat -c%s "$bam")
		redo_tmp_mb=$(( redo_tmp_mb + bytes * 115 / 100 / 1024 / 1024 ))
	done
	local redo_args=(-x "$xml" -c "$config_file")
	[ -n "$log_file" ] && redo_args+=(-l "$log_file")
	sbatch --tmp="${redo_tmp_mb}M" "$tools_folder/lima_redo.slurm" "${redo_args[@]}"
}

if [ -z "$config_file" ]; then
	config_file="${WGS_CONFIG_FILE:-}"
fi
if [ -z "$config_file" ]; then
	echo "No explicit config file given (-c) and default config var WGS_CONFIG_FILE is not set." 1>&2
	usage
fi
if [ ! -f "$config_file" ]; then
	echo "Config file not found: $config_file" 1>&2
	exit 1
fi

tools_folder="$(jq -r '.Paths.WGS_folder' "$config_file")/Tools/Lima"
if [ ! -d "$tools_folder" ]; then
	echo "Please put repo folder in config file under 'Path/WGS_folder'. Tools folder not found at: $tools_folder" 1>&2
	exit 1
fi

pbDir=$(dirname "$inputxml")
if [ ! -d "$pbDir" ]; then
  echo "Directory $pbDir does not exist."
  exit 1
fi
prefix=$(basename "$inputxml" .consensusreadset.xml)
mkdir -p "$pbDir/Lima_Reports/$prefix"

barcode=$(echo "$prefix" | cut -d'.' -f3)
echo "Processing barcode $barcode"

outxml="$pbDir/$prefix.lima-undo.consensusreadset.xml"

# Resume support: if a prior run already produced a valid lima-undo XML with both corrected
# BAMs present and non-empty, skip straight to launching lima_redo.slurm instead of re-copying
# and re-running lima-undo on BAMs that can be 100GB+.
if [ -f "$outxml" ] && xmllint --noout "$outxml" 2>/dev/null; then
	mapfile -t existing_bams < <(grep -oP 'ResourceId="\./\K[^"]+\.bam(?=")' "$outxml")
	undo_already_done=false
	if [ "${#existing_bams[@]}" -ge 2 ]; then
		undo_already_done=true
		for rel in "${existing_bams[@]}"; do
			[ -s "$pbDir/$rel" ] || { undo_already_done=false; break; }
		done
	fi
	if [ "$undo_already_done" = true ]; then
		echo "lima-undo already completed for $prefix ($outxml) - skipping straight to lima_redo.slurm"
		log_step "SUCCESS: lima-undo for $prefix (already done, skipped)"
		out_bams=()
		for rel in "${existing_bams[@]}"; do
			out_bams+=("$pbDir/$rel")
		done
		submit_lima_redo "$outxml" "${out_bams[@]}"
		exit 0
	fi
	echo "Found $outxml but its referenced BAM(s) are missing/empty - redoing lima-undo"
fi

cp -v "$inputxml" "$outxml"
sed -i "s/$barcode/unassigned/g" "$outxml"

echo "INXML $(basename "$inputxml")"
echo "OUTXML $(basename "$outxml")"

# Setup the apptainer image
if [ -z "${APPTAINER_CACHEDIR:-}" ]; then
	echo """Warning: You should set an explicit directory for APPTAINER_CACHEDIR in ~/.bashrc IE:
	export APPTAINER_TMPDIR="~/scratch/singularity_cache/tmp"
	export APPTAINER_CACHEDIR="/home/felixant/scratch/singularity_cache"
"""
	echo "Using scratch folder as APPTAINER_CACHEDIR for now"
	export APPTAINER_CACHEDIR="$SCRATCH/apptainer_cache"
	mkdir -p "$APPTAINER_CACHEDIR"
fi
image="$APPTAINER_CACHEDIR/lima_26.2.1_build3.sif"
if [ ! -f "$image" ]; then
	echo "Downloading lima container"
	apptainer pull "$image" docker://quay.io/pacbio/lima:26.2.1_build3
fi
#Local scratch
cp -v "$image" "$SLURM_TMPDIR/$(basename "$image")"
image="$SLURM_TMPDIR/$(basename "$image")"
apptainer exec -C "$image" lima-undo --version

THREADS=${SLURM_CPUS_PER_TASK:-3}

# lima-undo takes a BAM in and a BAM out directly (see `lima-undo --help`) - it has no
# dataset-XML support and no --alarms flag. The barcode-specific XML's own ResourceId points
# at a near-empty per-barcode BAM; the reads that actually need lima's manipulations undone
# live in the pooled "unassigned" BAM next to it, so derive that path instead of trusting it.
out_bams=()
for readType in "ConsensusReadBamFile:hifi_reads" "FailReadBamFile:fail_reads"; do
  metaType=${readType%%:*}
  dirName=${readType##*:}

  rel=$(grep -oP "MetaType=\"PacBio\.ConsensusReadFile\.${metaType}\"[^>]*ResourceId=\"\K[^\"]+\.bam" "$inputxml")
  echo "Readtype: $readType"
  echo "Rel: $rel"
  unassigned_rel=${rel/$barcode/unassigned}
  in_bam=$(realpath -m "$pbDir/$unassigned_rel")
  in_base=$(basename "$in_bam")
  out_base="${in_base%.bam}.lima-undo.bam"

  echo "Copying $in_base to scratch"
  cp -v "$in_bam" "$SLURM_TMPDIR/$in_base"
  [ -f "$in_bam.pbi" ] && cp -v "$in_bam.pbi" "$SLURM_TMPDIR/$in_base.pbi"

  apptainer exec -C -B "$SLURM_TMPDIR" "$image" \
    lima-undo \
    --log-level INFO \
    --num-threads "$THREADS" \
    --log-file "$SLURM_TMPDIR/lima-undo.$dirName.log" \
    "$SLURM_TMPDIR/$in_base" \
    "$SLURM_TMPDIR/$out_base"

  echo "Copying results back for $dirName"
  mv -v "$SLURM_TMPDIR/lima-undo.$dirName.log" "$pbDir/lima-undo.$dirName.log"
  cp -v "$SLURM_TMPDIR/$out_base" "$pbDir/$out_base"
  [ -f "$SLURM_TMPDIR/$out_base.pbi" ] && cp -v "$SLURM_TMPDIR/$out_base.pbi" "$pbDir/$out_base.pbi"

  # Point the output XML at the new local (same-directory) lima-undo BAM instead of the old
  # ../$dirName/ path, so it no longer resolves outside of $pbDir.
  sed -i "s,ResourceId=\"\.\./${dirName}/${in_base}\",ResourceId=\"./${out_base}\",g; s,ResourceId=\"\.\./${dirName}/${in_base}\.pbi\",ResourceId=\"./${out_base}\.pbi\",g" "$outxml"

  # Free scratch space before the next read type
  rm -f "$SLURM_TMPDIR/$in_base" "$SLURM_TMPDIR/$in_base.pbi" "$SLURM_TMPDIR/$out_base" "$SLURM_TMPDIR/$out_base.pbi"
  out_bams+=("$pbDir/$out_base")
done

# `set -e` only guarantees every command above exited 0 - it doesn't guarantee the BAMs/XML
# they produced are actually usable (e.g. a bad sed could silently write malformed XML
# without any command failing). Check the real outputs before handing off to lima_redo.slurm.
for bam in "${out_bams[@]}"; do
  if [ ! -s "$bam" ]; then
    echo "lima-undo output $bam is missing or empty - not launching lima_redo.slurm" >&2
    exit 1
  fi
done
if ! xmllint --noout "$outxml"; then
  echo "$outxml failed XML validation - not launching lima_redo.slurm" >&2
  exit 1
fi

log_step "SUCCESS: lima-undo for $prefix"

echo "lima-undo completed successfully, launching lima_redo.slurm"
submit_lima_redo "$outxml" "${out_bams[@]}"
