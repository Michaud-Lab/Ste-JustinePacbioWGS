#!/bin/bash
#
#SBATCH --time=8:00:00
#SBATCH --cpus-per-task=8
#SBATCH --output=J-%x.%j.out
#SBATCH --mem=64G
#SBATCH --tmp=200G

# Runs lima (from the PacBio lima apptainer image) to re-demultiplex the pooled
# "unassigned" BAMs (hifi_reads and fail_reads, both referenced by the same input
# dataset XML) produced by lima_undo.slurm.
#
# Arguments:
# -x <MOVIE.bcXXXX.lima-undo.consensusreadset.xml> (full absolute path, output of lima_undo.slurm)
# -c <config_file> (optional, defaults to $WGS_CONFIG_FILE)
# -l <log_file> (optional; overall job log to append SUCCESS/FAILED lines to)
#
# lima's split-per-barcode output on $SLURM_TMPDIR can total 100GB+ - the --tmp=100G above
# is only a floor for standalone runs; lima_undo.slurm overrides it with `sbatch --tmp=...`
# sized from the corrected BAMs it just produced.
#
#example call:
#sbatch lima_redo.slurm -x /home/felixant/links/projects/rrg-rallard/shared/PacBioDataRorqual/SequencerData/r84196_20251010_130733/1_B01/pb_formats/m84196_251010_201413_s3.hifi_reads.bc2090.lima-undo.consensusreadset.xml

set -eo pipefail
module load apptainer/1.3.5

usage() { echo "Usage: sbatch lima_redo.slurm -x /full/path/to/MOVIE.bcXXXX.lima-undo.consensusreadset.xml [-c <config_file>] [-l <log_file>]" 1>&2; exit 1; }

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
trap 'rc=$?; [ $rc -ne 0 ] && [ -n "${log_file:-}" ] && echo "[$(date +%Y-%m-%dT%H:%M:%S)] FAILED: lima-redo for ${inputxml:-?} (rc=$rc)" >> "$log_file"' EXIT

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
adapters_fasta="$tools_folder/SMRTbell_adapter_indexes.fasta"
if [ ! -f "$adapters_fasta" ]; then
	echo "Adapter indexes fasta not found at $adapters_fasta" 1>&2
	exit 1
fi

pbDir=$(dirname "$inputxml")
if [ ! -d "$pbDir" ]; then
  echo "Directory $pbDir does not exist."
  exit 1
fi
if [ ! -f "$inputxml" ]; then
  echo "Input XML file $inputxml does not exist."
  exit 1
fi
outxml=${inputxml%.lima-undo.consensusreadset.xml}.re-demuxed.consensusreadset.xml
# lima only demultiplexes one BAM type per invocation: by default the hifi_reads
# (ConsensusReadBamFile) entry, or - with --fail-reads-only - the fail_reads (FailReadBamFile)
# entry, even though the input dataset XML references both. So fail_reads needs its own pass,
# with its own output name so the two runs' split-per-barcode BAMs don't collide.
outxml_fail=${outxml/.hifi_reads./.fail_reads.}

echo "XML $inputxml"
echo "Output XML (hifi_reads) $outxml"
echo "Output XML (fail_reads) $outxml_fail"

# Resume support: skip whichever read type was already re-demuxed by a prior run (e.g. the
# hifi_reads-only bug this two-pass split fixed) instead of redoing it from scratch.
run_hifi=true
run_fail=true
if [ -f "$outxml" ] && xmllint --noout "$outxml" 2>/dev/null; then
	echo "$outxml already exists and is valid - skipping hifi_reads lima pass"
	run_hifi=false
fi
if [ -f "$outxml_fail" ] && xmllint --noout "$outxml_fail" 2>/dev/null; then
	echo "$outxml_fail already exists and is valid - skipping fail_reads lima pass"
	run_fail=false
fi
if [ "$run_hifi" = false ] && [ "$run_fail" = false ]; then
	echo "Both hifi_reads and fail_reads already re-demuxed - nothing to do"
	log_step "SUCCESS: lima-redo for $(basename "$inputxml" .lima-undo.consensusreadset.xml) (already done, skipped)"
	exit 0
fi

mkdir -p "$pbDir/Lima_Reports"
mkdir -p "$pbDir/Lima_Reports/$(basename "$inputxml" .consensusreadset.xml)"

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
apptainer exec -C "$image" lima --version

# `--split-subdirs` creates its per-barcode output directories relative to the current
# working directory, not relative to the output XML's own path - so run with --pwd
# $SLURM_TMPDIR (not $pbDir). Otherwise the split BAMs land directly in $pbDir,
# bypassing scratch entirely, and a retry after a failed run collides with whatever partial
# per-barcode files that previous attempt already left behind (pbbam's BAM writer refuses to
# overwrite an existing file). Running out of a fresh scratch dir avoids both problems.
run_lima_pass() {
	local pass_outxml="$1" pass_log="$2" pass_guess_json="$3"; shift 3
	apptainer exec -C -B "$HOME" -B "$SLURM_TMPDIR" --pwd "$SLURM_TMPDIR" "$image" \
		lima \
		-j 7 \
		--peek-guess \
		--log-level DEBUG \
		--log-file "$pass_log" \
		--hifi-preset SYMMETRIC-ADAPTERS \
		--dump-removed \
		--ignore-xml-biosamples \
		--split-bam-named \
		--split-subdirs \
		--output-missing-pairs \
		--guess-file-json "$pass_guess_json" \
		"$@" \
		"$inputxml" \
		"$adapters_fasta" \
		"$SLURM_TMPDIR/$(basename "$pass_outxml")"
}

if [ "$run_hifi" = true ]; then
	echo "Launching lima for hifi_reads"
	date
	run_lima_pass "$outxml" "$pbDir/lima-remux.log" "$pbDir/lima_guesses.report.json"
	echo "hifi_reads lima complete"
	date
fi

if [ "$run_fail" = true ]; then
	echo "Launching lima for fail_reads"
	date
	run_lima_pass "$outxml_fail" "$pbDir/lima-remux.fail_reads.log" "$pbDir/lima_guesses.fail_reads.report.json" --fail-reads-only
	echo "fail_reads lima complete"
	date
fi

#Copy back results (only for the pass(es) actually run above)
[ "$run_hifi" = true ] && cp -v "$SLURM_TMPDIR/$(basename "$outxml")" "$outxml"
[ "$run_fail" = true ] && cp -v "$SLURM_TMPDIR/$(basename "$outxml_fail")" "$outxml_fail"
cp -vr "$SLURM_TMPDIR"/bc* "$pbDir/"

#Remove SLURM_TMPDIR from paths in the output XML(s) just written
[ "$run_hifi" = true ] && sed -i "s,$SLURM_TMPDIR,\./,g" "$outxml"
[ "$run_fail" = true ] && sed -i "s,$SLURM_TMPDIR,\./,g" "$outxml_fail"

log_step "SUCCESS: lima-redo for $(basename "$inputxml" .lima-undo.consensusreadset.xml)"
