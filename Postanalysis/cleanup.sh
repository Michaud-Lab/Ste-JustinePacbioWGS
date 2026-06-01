#!/bin/bash

#A cleanup script meant to be run after samples are sent to GeneYX
#This is only meant to remove large intermediate files that are not needed anymore
#Arguments:
# $-i <familyID>
# $-d <directory to clean>
# $-c <optional config file (default .myconf.json)>

set -eu
echo "cleanup.sh Arguments:"
for var in "$@"; do
 echo $var
done
usage() { echo "Usage: $0 [-i <familyID>] [-d <directory to clean>] [-c <optional config file (default .myconf.json)>]" 1>&2; exit 1; }
config_file="$(dirname $0)/../.myconf.json"
while getopts ":i:d:c:" o; do
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
		c)
			config_file=${OPTARG}
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

samplesheet_dir=$(jq -r ".Paths.sample_sheet_path" $config_file)

if [ -f $samplesheet_dir/$family_id.txt ]; then
	family_sampleSheet="$samplesheet_dir/$family_id.txt"
else
	echo "Could not find samplesheet '$family_id.txt' in $samplesheet_dir"
	exit
fi

echo "Starting cleanup for  $family_id"

#The alignment step splits the bams, we don't need to save chunks. (the real aligned bam is in call-merge_hifi_bams/work/*GRCh38.bam)
rm -rf $directory/*/call-upstream-*/call-pbmm2-0/call-pbmm2_align_wgs-*
rm -rf $directory/*/call-upstream-*/call-pbmm2-0/call-split_input_bam/work*

rm -rf $directory/*/call-upstream-*/call-samtools_merge/work*
rm -rf $directory/*/call-*/call-merge_hifi_reads/work*

#We don't need to keep the merged bam with failed reads
rm -rf $directory/*/call-*/call-merge_hifi_fail_bams/work*
rm -rf $directory/*/call-*/call-bait_fail_reads-*/work*
rm -rf $directory/*/call-*/call-align_captured_fail_reads-*/work*

#The aligned bam is an intermediate we don't necessarily need
rm -rf $directory/*/call-*/call-merge_hifi_bams/work*

#The deepvariant model files take significant space and we no longer need them
rm -rf $directory/*/call-upstream-*/call-deepvariant/call-deepvariant_make_examples-*

echo "Ready to remove the following BAM directories if not on Rorqual:"
tail -n +2 $family_sampleSheet | while read line || [[ -n $line ]]; do
	bamFile=$(echo $line | cut -d, -f2 )
	bamDirectory=$(dirname $(dirname $bamFile))
	echo "$bamDirectory"
done