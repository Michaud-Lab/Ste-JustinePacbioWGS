#!/bin/bash
#SBATCH --job-name=Globus_${family_id}
#SBATCH --output=J-%x.%j.out
#SBATCH --account=def-rallard
#SBATCH --time=00:10:00

# This script is meant to use globus to send a fully processed folder
# This will ignore symlinks 

set -eu
echo "Arguments:"
for var in "$@"; do
 echo $var
done
usage() { echo "Usage: $0 [-i <familyID>] [-d <directory to clean>] [-c <optional config file (default .myconf.json)>] [-t <tools_folder>] [-m <mode> (duo/trio)] " 1>&2; exit 1; }
config_file="$(dirname $0)/../.myconf.json"
tools_folder="$(dirname $0)/../Tools/"
while getopts ":i:d:c:t:m:" o; do
	case "${o}" in
		i)
			family_id=${OPTARG}
			;;
		d)
			directory=${OPTARG}
			if [ ! -d "$directory" ]; then
				echo "Could not find directory $directory"
				exit
			fi
			;;
		t)
			#This should be in the repo, directory containing the globus environment and requirements
			tools_folder=${OPTARG}
			;;
		c)
			config_file=${OPTARG}
			;;
		m)
			mode=${OPTARG}
				if [ "$mode" != "duo" ] && [ "$mode" != "trio" ]; then
					echo "Invalid mode: $mode. Must be 'duo' or 'trio'."
					exit
				fi
			;;
		*)
			usage
			;;
	esac
done

if [ -z "${family_id:-}" ] || [ -z "${directory:-}" ]; then
	usage
fi

if [ ! -f "$config_file" ]; then
	echo "Could not find config file $config_file"
	exit
fi
# We start with a check of the steps that should have been done already
ok_to_send=true
summary_file="$directory/summary_report.txt"
echo "Step review for $family_id" > "$summary_file"
if [ -f "$directory/Peddy_analyses/${family_id}_peddy.html" ]; then
	echo "Peddy report found" >> "$summary_file"
else
	echo "Peddy report NOT FOUND" >> "$summary_file"
	ok_to_send=false
fi

if [ -d "$directory/SVTOPO_OUTPUTS" ]; then
	for d in "$directory"/SVTOPO_OUTPUTS/*/; do
		if [ -d "$d" ]; then # Check if it's a directory
			if [ ! -f "${d}index.html" ]; then
				echo "SVTOPO report NOT FOUND in ${d}" >> "$summary_file"
				ok_to_send=false
			else echo "SVTOPO report found in ${d}" >> "$summary_file"
			fi
		fi
	done
else
	echo "SVTOPO_OUTPUTS directory not found" >> "$summary_file"
	ok_to_send=false
fi


if [ -d "$directory/Triomix_analyses" ] && [ "$mode" == "trio" ]; then
	if ls "$directory"/Triomix_analyses/*.child.counts.plot.pdf 1> /dev/null 2>&1; then
		echo "Triomix report found" >> "$summary_file"
	else
		echo "Triomix report NOT FOUND" >> "$summary_file"
		ok_to_send=false
	fi
elif [ "$mode" == "trio" ]; then
	echo "Triomix_analyses directory not found" >> "$summary_file"
	ok_to_send=false
fi


if [ -f "$directory/multiqc_report.html" ]; then
	echo "MultiQC report found" >> "$summary_file"
else
	echo "MultiQC report NOT FOUND" >> "$summary_file"
	ok_to_send=false
fi


if [ "$ok_to_send" = false ]; then
	echo "Not sending to Narval, some steps are missing. Please check the summary report at $summary_file"
	exit
else echo "Attempting to send Transfer request to globus"
fi

# On Narval the default destination the path is:
destination_path="$(jq -r '.Transfers.destination_path' $config_file)"
destination_endpoint="$(jq -r '.Transfers.destination_endpoint' "${config_file}")" # Narval endpoint UUID
destination_collection="$(jq -r '.Transfers.destination_collection' "${config_file}")" # Narval collection UUID
source_endpoint="$(jq -r '.Transfers.working_endpoint' "${config_file}")"
source_collection="$(jq -r '.Transfers.working_collection' "${config_file}")"


ENVDIR=$tools_folder/ENV
if [ -d "$ENVDIR" ]; then
	echo "using existing environment at $ENVDIR"
	source $ENVDIR/bin/activate
else
	virtualenv --no-download $ENVDIR
	source $ENVDIR/bin/activate
	pip install --no-index --upgrade pip
	echo "Loading environment"
	pip install -r "$tools_folder/requirements.txt"
fi
globus transfer --label $family_id-transfer -r "${source_collection}:$directory" "${destination_collection}:${destination_path}/$family_id"

# cat << EOF > globusFlow_$family_id.json
# {
# 	"source": {
# 		"id": "$(jq -r '.Transfers.origin_collection' $config_file)",
# 		"path": "$directory/"
# 	},
# 	"destination": {
# 		"id": "$(jq -r '.Transfers.destination_collection' $config_file)",
# 		"path": "$destination_path/$family_id/"
# 	},
# 	"transfer_label": "Transfer $family_id to Narval",
# 	"verify_checksum": true
# }
# EOF
# cat globusFlow_$family_id.json
# move_flow=6336492e-e308-4a67-b78e-13684c747472 ##UUID of the move and delete flow
# globus flows start --input file:globusFlow_$family_id.json $move_flow 
# rm globusFlow_$family_id.json