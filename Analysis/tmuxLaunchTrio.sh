#!/usr/bin/env bash

#This is meant to be a second version of tmuxTrios.sh meant to accomodate duos and 
#families containing a different amount of members. 
#Still uses a samplesheet in format:

set -euo pipefail

usage() { echo "Usage: $0 [-i <ID>] [-c <Optional_config_file (default env var WGS_CONFIG_FILE)>]" 1>&2; exit 1; }
config_file=""
 if [ "$#" -eq 0 ]; then
        echo "Error: No arguments supplied."
        usage
fi

while getopts ":i:c:" o; do
    case "${o}" in
        i)
            id=${OPTARG}
            
            ;;
        c)
            config_file=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done

if [ -z "${id:-}" ]; then
    usage
fi

if [ -z "${config_file}" ]; then
	config_file="${WGS_CONFIG_FILE:-}"
fi
if [ -z "${config_file}" ]; then
	echo "No explicit config file given (-c) and default config var WGS_CONFIG_FILE is not set." 1>&2
	echo "You can set one with 'export WGS_CONFIG_FILE=<path to config file>'" 1>&2
	exit 1
fi
if [ ! -f "${config_file}" ]; then
	echo "Config file not found: ${config_file}" 1>&2
	exit 1
fi

generic_samplesheet_path=$(python3 -c "import json; print(json.load(open('${config_file}'))['Paths']['sample_sheet_path'])")
if [ ! -f "${generic_samplesheet_path}/$id.json" ]; then
	echo "SampleSheet path not found! Need json for $id in ${generic_samplesheet_path}"
	exit 1
fi
sample_sheet_path="${generic_samplesheet_path}/$id.json"

miniwdl_cfg_path=$(python3 -c "import json; print(json.load(open('${config_file}'))['Paths']['miniwdl_cfg'])")
if [ ! -f "${miniwdl_cfg_path}" ]; then
	echo "Miniwdl config file not found!"
	exit 1
fi

output_dir=$(python3 -c "import json; print(json.load(open('${config_file}'))['Paths']['output_path'])")
output="${output_dir}/$id"

module load apptainer/1.3.5
#First row contains info on family
mkdir -p $output
sed -i -e 's/"affected": "False"/"affected": false/g' $sample_sheet_path
sed -i -e 's/"affected": "True"/"affected": true/g' $sample_sheet_path
tmux new -d -s $id
tmux send-keys -t $id "module load apptainer/1.3.5" Enter
tmux send-keys -t $id "miniwdl run Analysis/HiFi-human-WGS-WDL/workflows/family.wdl -i ${sample_sheet_path} --cfg ${miniwdl_cfg_path} -v -d $output" Enter