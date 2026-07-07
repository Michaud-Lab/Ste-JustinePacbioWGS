#!/bin/bash
#SBATCH --job-name=Globus_${family_id}
#SBATCH --output=J-%x.%j.out
#SBATCH --account=def-rallard
#SBATCH --time=00:10:00

# This script is meant to use globus to send a fully processed folder
# Globus will ignore symlinks, so we also do a rsync -l command only for symlinks
# This will depend on the -r argument

set -eo pipefail
echo "Arguments:"
for var in "$@"; do
 echo $var
done
usage() { echo "Usage: $0 [-i <familyID>] [-d <directory to clean>] [-c <optional config file (default .myconf.json)>] [-t <tools_folder>] [-m <mode> (duo/trio)] " 1>&2; exit 1; }
config_file="$(dirname $0)/../.myconf.json"
tools_folder="$(dirname $0)/../Tools/"
log_file=""
send_status_log=""
while getopts ":i:d:c:t:m:l:r:S:" o; do
	case "${o}" in
		i)	family_id=${OPTARG}	;;
		d)
			directory=${OPTARG}
			if [ ! -d "$directory" ]; then
				echo "Could not find directory $directory"
				exit
			fi
			;;
		#This should be in the repo, directory containing the globus environment and requirements
		t)	tools_folder=${OPTARG}	;;
		c)	config_file=${OPTARG}	;;
		m)
			mode=${OPTARG}
				if [ "$mode" != "duo" ] && [ "$mode" != "trio" ]; then
					echo "Invalid mode: $mode. Must be 'duo' or 'trio'."
					exit
				fi
			;;
		l)	log_file=${OPTARG}	;;
		S)	send_status_log=${OPTARG}	;;
		*)	usage	;;
	esac
done
log_step() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; [ -n "${log_file:-}" ] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$log_file"; }
trap 'rc=$?; [ $rc -ne 0 ] && [ -n "${log_file:-}" ] && echo "[$(date +%Y-%m-%dT%H:%M:%S)] FAILED: globus_send for ${family_id:-?} (rc=$rc)" >> "$log_file"' EXIT

if [ -z "${family_id:-}" ] || [ -z "${directory:-}" ]; then
	usage
fi

if [ ! -f "$config_file" ]; then
	echo "Could not find config file $config_file"
	exit
fi

# On Narval the default destination the path is:
destination_path="$(jq -r '.Transfers.destination_path' $config_file)"
destination_endpoint="$(jq -r '.Transfers.destination_endpoint' "${config_file}")" # Narval endpoint UUID
destination_collection="$(jq -r '.Transfers.destination_collection' "${config_file}")" # Narval collection UUID
source_endpoint="$(jq -r '.Transfers.working_endpoint' "${config_file}")"
source_collection="$(jq -r '.Transfers.working_collection' "${config_file}")"

# We start with a check of the steps that should have been done already
ok_to_send=true
summary_file="$directory/summary_report.txt"
echo "Step review for $family_id" > "$summary_file"
peddy_report="$directory/Peddy_analyses/${family_id}_peddy.ped_check.csv"
if [ -f "$peddy_report" ]; then
	echo "Peddy report found" >> "$summary_file"
	# Check if a Parent error was found:
	if awk -F',' '{print $13}' "$peddy_report" | grep -qx "True"; then 
		echo "Parent error identified by peddy: $peddy_report" >> "$summary_file"
		ok_to_send=false
	else 
		echo "No error identified by peddy" >> "$summary_file"
	fi
else
	echo "Peddy report NOT FOUND: $peddy_report" >> "$summary_file"
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

# Concordance check
readarray -t different_files < <(find $directory/Concordance/ -type f -name "*.txt" -exec grep -l "DIFFERENT" {} +)
readarray -t same_files < <(find "$directory/Concordance/" -type f -name "*.txt" -exec grep -l "SAME" {} +)
if [ ! -z "$different_files" ]; then
	echo "Found files with concordance <75%:" >> "$summary_file"
	printf '%s\n' "${different_files[@]}" >> "$summary_file"
	ok_to_send=false
fi
if ([ $mode == "duo" ] && [ ${#same_files[@]} == 2 ]) || ([ $mode == "trio" ] && [ ${#same_files[@]} == 3 ]); then
	echo "All SR-LR samples concord" >> "$summary_file"
else
	echo "Not the correct number of confirmed files? Found ${#same_files[@]}:" >> "$summary_file"
	printf '%s\n' "${same_files[@]}" >> "$summary_file"
fi


if [ "$ok_to_send" = false ]; then
	echo "Not sending to Narval, some steps are missing. Please check the summary report at $summary_file"
	exit
else echo "Attempting to send Transfer request to globus"
fi

ENVDIR=$tools_folder/ENV
if [ -d "$ENVDIR" ]; then
	echo "using existing environment at $ENVDIR"
	source $ENVDIR/bin/activate
else
	module load python/3.11 scipy-stack/2026a
	virtualenv --no-download $ENVDIR
	source $ENVDIR/bin/activate
	pip install --no-index --upgrade pip
	echo "Loading environment"
	pip install -r "$tools_folder/requirements.txt"
fi
globus transfer --label $family_id-transfer -r "${source_collection}:$directory" "${destination_collection}:${destination_path}/$family_id"
log_step "SUCCESS: globus transfer for ${family_id}"
if [ -n "${send_status_log:-}" ]; then
	if grep -q "^globus_send:" "$send_status_log" 2>/dev/null; then
		sed -i "s|^globus_send:.*|globus_send: SUCCESS|" "$send_status_log"
	else
		echo "globus_send: SUCCESS" >> "$send_status_log"
	fi
fi
