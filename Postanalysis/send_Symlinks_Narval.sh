#!/bin/bash
#SBATCH --job-name=multiqc_${family_id}
#SBATCH --output=J-%x.%j.out
#SBATCH --account=def-rallard
#SBATCH --mem=4G
#SBATCH --time=01:00:00

# This script is meant to dar a fully processed folder
# then send it to Narval
# Note that you can use the robot nodes to automate this
# Follow the instructions here: 
# https://msss365-my.sharepoint.com/:p:/g/personal/nicolas_perrot_hsj_ssss_gouv_qc_ca/IQBk4eS7U82LS7RY-GDUzAotAb5FslgG8GfcCOw3VRsNF0s?e=3xbdHn 
# If you don't have access to NarvalInteractiveRobot, you can use the default Narval login
# but you will have to enter your password manually

# On Narval the default destination the path is:
destination_path="$HOME/projects/ctb-rallard/COMMUN/PacBioData/OutputFamilies"


set -eu
echo "send_Symlinks_Narval Arguments:"
for var in "$@"; do
 echo $var
done
usage() { echo "Usage: $0 [-i <familyID>] [-d <directory to clean>] [-c <optional config file (default env var WGS_CONFIG_FILE)>]" 1>&2; exit 1; }
config_file=""
cluster="narval.alliancecan.ca"
use_robot="False"
while getopts ":i:d:c:r" o; do
	case "${o}" in
		i)
			family_id=${OPTARG} ;;
		d)
			directory=${OPTARG}
			if [ ! -d "$directory" ]; then
				echo "Could not find directory $directory"
				exit
			fi
			;;
		c)
			config_file=${OPTARG} ;;
		r)
			use_robot="True" ;;
		*)
			usage ;;
	esac
done

if [ -z "${family_id:-}" ] || [ -z "${directory:-}" ]; then
	usage
fi

if [[ -z "$config_file" ]]; then
	config_file="${WGS_CONFIG_FILE:-}"
fi
if [[ -z "$config_file" ]]; then
	echo "No explicit config file given (-c) and default config var WGS_CONFIG_FILE is not set." 1>&2
	usage
fi
if [[ ! -f "$config_file" ]]; then
	echo "Config file not found: $config_file" 1>&2
	exit 1
fi

if [[ $use_robot == "True" ]];then
	echo "Send symlink step tries to send with automation"
	#Use robot node (automation but requires setup)
	cluster="robot.narval.alliancecan.ca"
	identity_file=$(jq -r '.Transfers.identity_file' "$config_file")
	if [ ! -f "$identity_file" ]; then
		echo "Could not find identity file $identity_file"
		exit
	fi
	identity_line="-e \"ssh -i $identity_file\""
else
	echo "Send symlink step tries to send without automation"
	identity_line=""
fi

#We send only symlinks to allow globus to do the real file transfers
#(Globus avoids symlinks)
echo "Sending symlinks from $directory to $USER@$cluster:$destination_path/$family_id"
if [ ! -n "$identity_line" ]; then
	find "$directory" -type l -printf '%P\n' | \
		rsync -rl --files-from=- "$directory" "$USER@$cluster:$destination_path/$family_id"
else
	find "$directory" -type l -printf '%P\n' | \
		rsync -rl -e "ssh -i $identity_file" --files-from=- "$directory" "$USER@$cluster:$destination_path/$family_id"
fi
