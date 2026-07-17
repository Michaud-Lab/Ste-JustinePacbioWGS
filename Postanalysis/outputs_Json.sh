#!/bin/bash

# This script is meant to make the symlinks in a S3-Storage folder 
# and fix the links in the outputs.json file

# The correct path will depend on the destination of the files
# For example, on Narval (the default), the path is:
destination_path="$HOME/projects/ctb-rallard/COMMUN/PacBioData/OutputFamilies"

#Arguments:
# $-i <familyID>
# $-d <directory to clean>
# $-c <optional config file (default .myconf.json)>

set -eu
echo "outputs_Json.sh Arguments:"
for var in "$@"; do
 echo $var
done
usage() { echo "Usage: $0 [-i <familyID>] [-d <directory to clean>] [-c <optional config file (default .myconf.json)>]" 1>&2; exit 1; }
config_file="$(dirname $0)/../.myconf.json"
while getopts ":i:d:c:" o; do
    case "${o}" in
        i)	family_id=${OPTARG}	;;
        d)
            directory=${OPTARG}
			if [ ! -d "$directory" ]; then
				echo "Could not find directory $directory"
				exit
			fi
            ;;
		c)	config_file=${OPTARG}	;;
		*)	usage	;;
    esac
done

if [ -z "${family_id:-}" ] || [ -z "${directory:-}" ]; then
	usage
fi

if [ ! -f "$config_file" ]; then
	echo "Could not find config file $config_file"
	exit
fi

touch cleanupReport.txt

samplesheet_dir=$(jq -r ".Paths.sample_sheet_path" $config_file)
s3_local=$(jq -r ".Paths.s3_folder" $config_file)

if [ -f $samplesheet_dir/$family_id.txt ]; then
	family_sampleSheet="$samplesheet_dir/$family_id.txt"
else
	echo "Could not find samplesheet '$family_id.txt' in $samplesheet_dir"
	exit
fi

outputs_file="$directory/_LAST/outputs.json"
if [ ! -f "$outputs_file" ]; then
	echo "Could not find outputs.json file in $directory/_LAST/"
	exit
fi

#Set the correct paths in outputs.json to the new folder
destination_absolute_path="$destination_path/$family_id"
tmp=$(jq -r '.["humanwgs_family.bam_statistics"][0]' $outputs_file)
my_dirname=$(basename "$directory")
local_absolute_path_prefix=${tmp%/$my_dirname/*}/$my_dirname
echo "Updating paths in $outputs_file to point from $local_absolute_path_prefix to $destination_absolute_path"
sed -i.bak2 "s,$local_absolute_path_prefix,$destination_absolute_path,g" "$outputs_file"


function updateSymlink() {
	local index=$1 			# the key in outputs.json
	local new_filename=$2 	# The name the file should have in S3-Storage
	local old_path=$3		# The absolute path of the destination, will need to be replaced by...
	local new_path=$4		# ...the relative path to the Output Folder in destination
	local name=$5			# The individual sample name
	local roleDestination=$6
	local full_filepath=$(jq -r --arg index1 $index '.[$index1][]' $outputs_file | grep $name)
	local new_filepath=${full_filepath/$old_path/$new_path}
	ln -sf "$new_filepath" "$roleDestination/${new_filename}"
}

mkdir -p "$s3_local/$family_id"
tail -n +2 "$family_sampleSheet" | while read p; do
	role=$(echo $p | cut -d: -f1)
	name=$(echo $p | cut -d, -f1 | cut -d: -f2)
	s3_role_destination="$s3_local/$family_id/$role"
	mkdir -p "$s3_role_destination"

	# The symlink destination needs to be updated to reflect the correct path
	# When sending to Narval, the path should be ../../../OutputFamilies/$directory
	# Because we want to keep relative paths to avoid user-specific absolute paths

	new_path="../../../OutputFamilies/$family_id"

	#This is a file to keep track of all samples and their new locations
	echo "$role/$name/$family_id,$destination_absolute_path/" >>fullsampleSheet.csv

	updateSymlink "humanwgs_family.merged_haplotagged_bam" "${name}.haplotagged.bam" "$destination_absolute_path" "$new_path" "$name" "$s3_role_destination"
	updateSymlink "humanwgs_family.merged_haplotagged_bam_index" "${name}.haplotagged.bam.bai" "$destination_absolute_path" "$new_path" "$name" "$s3_role_destination"
	updateSymlink "humanwgs_family.cpg_combined_bed" "${name}.GRCh38.cpg_pileup.combined.bed.gz"  "$destination_absolute_path" "$new_path" "$name" "$s3_role_destination"
	updateSymlink "humanwgs_family.cpg_combined_bed_index" "${name}.GRCh38.cpg_pileup.combined.bed.gz.tbi"  "$destination_absolute_path" "$new_path" "$name" "$s3_role_destination"
	updateSymlink "humanwgs_family.cpg_hap1_bed" "${name}.GRCh38.cpg_pileup.hap1.bed.gz" "$destination_absolute_path" "$new_path" "$name" "$s3_role_destination"
	updateSymlink "humanwgs_family.cpg_hap1_bed_index" "${name}.GRCh38.cpg_pileup.hap1.bed.gz.tbi" "$destination_absolute_path" "$new_path" "$name" "$s3_role_destination"
	updateSymlink "humanwgs_family.cpg_hap2_bed" "${name}.GRCh38.cpg_pileup.hap2.bed.gz" "$destination_absolute_path" "$new_path" "$name" "$s3_role_destination"
	updateSymlink "humanwgs_family.cpg_hap2_bed_index" "${name}.GRCh38.cpg_pileup.hap2.bed.gz.tbi" "$destination_absolute_path" "$new_path" "$name" "$s3_role_destination"
done



s3_destination="$HOME/projects/ctb-rallard/COMMUN/PacBioData/S3-Storage/"
echo "Sending S3-Storage to Narval: $destination_path/$family_id"
rsync -rl $s3_local/$family_id "NarvalInteractiveRobot:$s3_destination"
echo "Rsync Complete"

REMOTE_BASE_PREFIX=$(jq -r '.Rclone.s3_bam_storage' "$config_file")
rclone_log="$directory/rclone_${family_id}_$(date +'%Y-%m-%d_%H-%M-%S').log"
echo "Running Rclone send to $REMOTE_BASE_PREFIX in background (log: $rclone_log)"
nohup rclone copy -L "$s3_destination/$family_id" "$REMOTE_BASE_PREFIX:decodeur-pacbio/S3-Storage/$family_id" \
	>"$rclone_log" 2>&1 &
rclone_pid=$!
disown
echo "Rclone running in background (PID $rclone_pid)"