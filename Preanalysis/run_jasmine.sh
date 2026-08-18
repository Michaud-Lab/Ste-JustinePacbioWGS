#!/bin/bash
#
# This is meant to run the jasmine.slurm sbatch script on ALL samples in a run.
# For each well/cell folder in the run, it locates the hifi consensusreadset XML
# under pb_formats/ and submits one jasmine.slurm job for it, logging the
# resulting job ID so submissions can be tracked/followed up on later.
set -eo pipefail


usage() {
    echo "Usage: $0 [-r <run_id> ] [-t <jasmine_version>] [-c <config_file>]" 1>&2
    exit 1
}

config_file="$SCRATCH/Ste-JustinePacbioWGS/.myconf.json"
JASMINE_VERSION="2.0.0"
while getopts "r:t:c:" opt; do
    case "${opt}" in
		r)	run_id="${OPTARG}" ;;
        t)  JASMINE_VERSION="${OPTARG}" ;;
        c)  config_file="${OPTARG}" ;;
        :)  echo "Error: -${OPTARG} requires an argument."; usage ;;
        *)  usage ;;
    esac
done

if [ -z "$run_id" ]; then 
	usage
fi
# default value for config
if [ ! -f "$config_file" ]; then
	if [ -f "$(dirname "$0")/.myconf.json" ]; then
		config_file="$(dirname "$0")/.myconf.json"
	else
		echo "config file not found: $config_file. You can input one with option '-c'"
		exit 1
	fi
fi

# run_path in the config points to the folder containing one subfolder per run;
# the run itself contains one subfolder per well/cell (ie 1_A01, 1_B01...)
all_runs_folder=$(jq -r '.Paths.run_path' "$config_file")
run_folder="$all_runs_folder/$run_id"
if [ ! -d "$run_folder" ]; then
	echo "Run ID folder was not found in $run_folder"
	exit 1
fi
# Tracks which cell folder maps to which submitted Slurm job ID, for later follow-up
overall_job_log="$(dirname $0)/jasmine_run_$run_id.log"
 >"$overall_job_log"
for cell_folder in "$run_folder"/*/; do
	echo "Cell folder: $cell_folder"
	if [ ! -d "$cell_folder/pb_formats" ]; then
		echo "pb_format folder not found in $cell_folder. Skipping"
		continue
	fi

	# jasmine.slurm touches this marker only after it fully succeeds for this version;
	# skip cells that were already launched and completed successfully.
	done_marker="$cell_folder/pb_formats/.jasmine_${JASMINE_VERSION}.done"
	if [ -f "$done_marker" ]; then
		echo "Cell $cell_folder already completed for jasmine $JASMINE_VERSION. Skipping"
		continue
	fi

	# The consensusreadset XML name embeds the well's barcode (bcXXXX); there should be exactly one per well
	shopt -s nullglob
	xml_matches=("$cell_folder/pb_formats"/*.hifi_reads.bc[0-9][0-9][0-9][0-9].consensusreadset.xml)
	shopt -u nullglob
	if [ "${#xml_matches[@]}" -eq 0 ]; then
		echo "Error: no hifi_reads consensusreadset XML found in $cell_folder/pb_formats. Skipping"
		continue
	fi
	if [ "${#xml_matches[@]}" -gt 1 ]; then
		echo "Error: expected exactly one hifi_reads consensusreadset XML in $cell_folder/pb_formats, found ${#xml_matches[@]}: ${xml_matches[*]}. Skipping"
		continue
	fi
	xml_file="${xml_matches[0]}"
	echo "$xml_file"
	echo "sbatch -D $cell_folder/pb_formats $(dirname $0)/jasmine.slurm -x $xml_file -t $JASMINE_VERSION -c $config_file"
	job_id=$(sbatch --parsable -D "$cell_folder/pb_formats" "$(dirname $0)/jasmine.slurm" -x "$xml_file" -t "$JASMINE_VERSION" -c "$config_file")
	echo "Submitted job $job_id"
	echo "$cell_folder job id: $job_id" >>"$overall_job_log"
done

