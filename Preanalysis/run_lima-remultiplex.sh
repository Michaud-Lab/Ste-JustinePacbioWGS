#!/bin/bash
#
# This is meant to run lima_undo.slurm on ALL wells/cells in a run, to sequentially
# undo lima's original barcode assignment and then re-run lima to remultiplex.
# For each well/cell folder in the run, it locates the hifi_reads consensusreadset
# XML under pb_formats/ and submits one lima_undo.slurm Slurm job for it.
#
# lima_undo.slurm itself handles both the hifi_reads and fail_reads BAMs for the well
# (it derives the fail_reads path from the hifi_reads one) and, once it succeeds,
# chains into lima_redo.slurm on its own - so submitting the single hifi_reads XML per
# well is enough to remultiplex both read types.
set -eo pipefail


usage() {
    echo "Usage: $0 [-r <run_id>] [-c <config_file>]" 1>&2
    exit 1
}
config_file=""
while getopts "r:c:" opt; do
    case "${opt}" in
		r)	run_id="${OPTARG}" ;;
        c)  config_file="${OPTARG}" ;;
        :)  echo "Error: -${OPTARG} requires an argument."; usage ;;
        *)  usage ;;
    esac
done

if [ -z "$run_id" ]; then
	usage
fi

if [ -z "$config_file" ]; then
	config_file="${WGS_CONFIG_FILE:-}"
fi
if [ -z "$config_file" ]; then
	echo "No explicit config file given (-c) and default config var WGS_CONFIG_FILE is not set." 1>&2
	echo "You can set one with 'export WGS_CONFIG_FILE=<path to config file>'" 1>&2
	exit 1
fi
if [ ! -f "$config_file" ]; then
	echo "Config file not found: $config_file" 1>&2
	exit 1
fi

#Folder of the repo
scripts_folder=$(jq -r '.Paths.WGS_folder' "$config_file")/Preanalysis
if [ ! -d "$scripts_folder" ]; then
	echo "Please set 'WGS_folder' setting under 'Paths' in config file."
	exit 1
fi
# run_path in the config points to the folder containing one subfolder per run;
# the run itself contains one subfolder per well/cell (ie 1_A01, 1_B01...)
all_runs_folder=$(jq -r '.Paths.run_path' "$config_file")
run_folder="$all_runs_folder/$run_id"
if [ ! -d "$run_folder" ]; then
	echo "Run ID folder was not found in $run_folder"
	exit 1
fi

lima_tools_folder=$(jq -r '.Paths.WGS_folder' "$config_file")/Tools/Lima
if [ ! -d "$lima_tools_folder" ]; then
	echo "Lima tools folder not found at $lima_tools_folder"
	exit 1
fi

# lima_undo.slurm stages the pooled "unassigned" hifi_reads/fail_reads BAMs on node-local
# scratch ($SLURM_TMPDIR), one read type at a time (input+output, then freed before the
# next). These BAMs can be 100GB+, and node-local disk on this cluster is a shared pool
# unless a job explicitly reserves some via --tmp - so size the reservation from the actual
# BAM referenced by the read type's own dataset XML, rather than trusting a fixed guess.
estimate_undo_tmp_mb() {
	local xml="$1" pbdir prefix barcode metaType dirName rel unassigned_rel bam_path bytes max_bytes=0
	pbdir=$(dirname "$xml")
	prefix=$(basename "$xml" .consensusreadset.xml)
	barcode=$(echo "$prefix" | cut -d'.' -f3)
	for readType in "ConsensusReadBamFile:hifi_reads" "FailReadBamFile:fail_reads"; do
		metaType=${readType%%:*}
		dirName=${readType##*:}
		rel=$(grep -oP "MetaType=\"PacBio\.ConsensusReadFile\.${metaType}\"[^>]*ResourceId=\"\K[^\"]+\.bam" "$xml") || true
		[ -z "$rel" ] && continue
		unassigned_rel=${rel/$barcode/unassigned}
		bam_path=$(realpath -m "$pbdir/$unassigned_rel")
		[ -f "$bam_path" ] || continue
		bytes=$(stat -c%s "$bam_path")
		[ "$bytes" -gt "$max_bytes" ] && max_bytes=$bytes
	done
	# Peak usage is in+out for the larger read type; add a 10% margin plus ~2GB headroom
	# for the apptainer image and lima-undo's own logs/buffers.
	echo $(( max_bytes * 22 / 10 / 1024 / 1024 + 2048 ))
}

# Tracks which cell folder maps to which submitted Slurm job ID, for later follow-up
overall_job_log="$scripts_folder/lima-remultiplex_run_$run_id.log"
 >"$overall_job_log"
for cell_folder in "$run_folder"/*/; do
	echo "Cell folder: $cell_folder"
	pb_formats="$cell_folder/pb_formats"
	if [ ! -d "$pb_formats" ]; then
		echo "pb_formats folder not found in $cell_folder. Skipping"
		continue
	fi

	# lima_redo.slurm (chained by lima_undo.slurm) writes these next to each other once remultiplexing
	# fully succeeds - lima only demultiplexes one read type per pass, so both markers must be
	# present before a cell can be considered done (a cell with only the hifi_reads marker,
	# e.g. from before lima_redo.slurm gained its separate fail_reads pass, must be resubmitted).
	shopt -s nullglob
	redemux_hifi_matches=("$pb_formats"/*.hifi_reads.bc[0-9][0-9][0-9][0-9].re-demuxed.consensusreadset.xml)
	redemux_fail_matches=("$pb_formats"/*.fail_reads.bc[0-9][0-9][0-9][0-9].re-demuxed.consensusreadset.xml)
	shopt -u nullglob
	if [ "${#redemux_hifi_matches[@]}" -gt 0 ] && [ "${#redemux_fail_matches[@]}" -gt 0 ]; then
		echo "Cell $cell_folder already re-demuxed (hifi_reads and fail_reads). Skipping"
		continue
	fi

	# The consensusreadset XML name embeds the well's barcode (bcXXXX); there should be exactly one per well
	shopt -s nullglob
	xml_matches=("$pb_formats"/*.hifi_reads.bc[0-9][0-9][0-9][0-9].consensusreadset.xml)
	shopt -u nullglob
	if [ "${#xml_matches[@]}" -eq 0 ]; then
		echo "Error: no hifi_reads consensusreadset XML found in $pb_formats. Skipping"
		continue
	fi
	if [ "${#xml_matches[@]}" -gt 1 ]; then
		echo "Error: expected exactly one hifi_reads consensusreadset XML in $pb_formats, found ${#xml_matches[@]}: ${xml_matches[*]}. Skipping"
		continue
	fi
	xml_file=$(realpath "${xml_matches[0]}")
	echo "$xml_file"
	tmp_mb=$(estimate_undo_tmp_mb "$xml_file")
	echo "sbatch --tmp=${tmp_mb}M -D $pb_formats $lima_tools_folder/lima_undo.slurm -x $xml_file -c $config_file -l $overall_job_log"
	job_id=$(sbatch --parsable --tmp="${tmp_mb}M" -D "$pb_formats" -J "Lima_undo_$(basename "$cell_folder")" "$lima_tools_folder/lima_undo.slurm" -x "$xml_file" -c "$config_file" -l "$overall_job_log")
	echo "Submitted job $job_id"
	echo "$cell_folder job id: $job_id" >>"$overall_job_log"
done
echo "All jobs launched" >>"$overall_job_log"
