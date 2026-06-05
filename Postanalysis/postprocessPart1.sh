#!/bin/bash
#
set -eo pipefail

#This version is meant to accelerate the interactive processes by asking the questions first
#Steps can be skipped if prompted at the start
#If any step fails the script will exit, then you can retry and skip the succeeded steps

#Upload files to geneyx according to their API for trios. 
#Provide the trio name as input. 
#First, it will use geneYX's script "PacBioUnifyVCF.py" with the 3 necessary vcfs
#Then, we build a JSON file with the paths to the correct files and use geneYX's "JSON_Sample_upload.py" to send the files over.
#Finally, we send "Cases" to start the analysis for the new files
#Postprocessing is done last, which includes :
#PEDDY report, 
#multiqc report,
#44SNP comparison with short reads (if desired, currently non-functionnal outside Narval)
#Cleanup and storage to /projects/share/PacBioDataRorqual/OutputFamilies

module load python/3.11 htslib/1.22.1 bcftools/1.22 bedtools/2.31.0 apptainer/1.3.5 arrow/21.0.0 libyaml

usage() { 
	printf "Usage: \n $0 [-i <familyID>]  [-g <group (i.e. prag,decode,valid /p,d,v)>] \n
 [-s {to run every step, otherwise will enter interactive mode}] \n
 [-c <Optional_config_file>] \n" 
 1>&2; exit 1; }

run_all=false
while getopts "i:c:g:s" o; do
	case "${o}" in
		i)
			id=${OPTARG}
			echo "Family ID set to: $id"
			;;
		c)
			config_file=${OPTARG}
			;;
		g)
			group=${OPTARG}
			if [ "$group" == "Pragmatiq" ] || [ "$group" == "prag" ] || [ "$group" == "p" ]; then
				echo "Using Pragmatiq group"
				group_name="Pragmatiq"
				group_code="prag"
			elif [ "$group" == "Decodeur" ] || [ "$group" == "decode" ] || [ "$group" == "d" ]; then
				echo "Using Decodeur group"
				group_name="Decodeur"
				group_code="decode"
			elif [ "$group" == "Validation" ] || [ "$group" == "valid" ] || [ "$group" == "v" ]; then
				echo "Using Validation group"
				group_name="Validation"
				group_code="validation"
			else 
				echo "Use either 'Pragmatiq' or 'Decodeur' or 'Validation' for group name or their code 'prag' or 'decode', 'valid' or 'p','d' or 'v'"
				exit
			fi
			;;
		s)
			run_all=true
			;;
		:)
			echo "Error: -${OPTARG} requires an argument."
			exit 1
			;;
		*)
			usage
			;;
	esac
done


here_folder=$(realpath "$(dirname $0)") #Postanalysis folder
tools_folder="$here_folder/../Tools"
if [ -z "$1" ]; then
	usage
fi

if [ -z "${id}" ] || [ -z "${group}" ]; then
	usage
fi
if [ -z "${config_file:-}" ]; then
	echo "No config file provided, using default location $here_folder/../.myconf.json"
	config_file="$here_folder/../.myconf.json"
elif [ ! -f "${config_file}" ]; then
	echo "Config file not found!"
	usage
fi

samplesheet=$(jq -r '.Paths.sample_sheet_path' ${config_file})/${id}.json

#------Functions------#
#This function loads the environment for GeneYX scripts
function loadEnv(){
	ENVDIR=$tools_folder/$1
	if [ -d "$ENVDIR" ]; then
		source $ENVDIR/bin/activate
	else
		virtualenv --no-download $ENVDIR
		source $ENVDIR/bin/activate
		pip install --no-index --upgrade pip
		if [ "$1" == "GeneYX_env" ]; then
			echo "Loading GeneYX environment"
			pip install -r $tools_folder/requirementsGeneYXUpload.txt
		elif [ "$1" == "Globus_env" ]; then
			echo "Loading Globus environment"
			pip install -r $tools_folder/requirementsGlobus.txt
		fi
	fi
}

function ask_yes_no() {
	local question="$1"
	local var_name="$2"
	local result
	echo "$question"
	select yn in "yes" "no"; do
		case $yn in
		yes)
			result=true; break ;;
		no)
			result=false; break ;;
		*)
			echo "please select 1 or 2" ;;
		esac
	done
	echo "$question: $yn" >> $report_file
	printf -v "$var_name" '%s' "$result"
}

#Left-align and normalize SNV VCF for GeneYX
function Normalize() {
	echo normalizing $1 >> "$report_file"
	local norm_output="$directory/$1.$family_id.normed.joint.GRCh38.small_variants.phased.vcf.gz"
	if [[ ! -f "$norm_output" ]]; then
		bcftools norm -m-any --check-ref -w -f "$fasta_path" -Oz -o "$norm_output" "$2" >> "$report_file" 2>&1
	fi
	if [ ! -f "$norm_output.tbi" ]; then
		tabix -p vcf "$norm_output"
	fi
	if [ -f "$norm_output" ] && [ -f "$norm_output.tbi" ]; then
		echo "Normalization ok for $1" >> "$report_file"
	else exit 1
	fi
	echo "$norm_output"
}

#Unifies the 4 differemt VCFs must be done for all samples in group
function UnifyVCF() {
	local unify_output="$directory/$1-unifiedTrioVCFv2.vcf.gz"
	echo "Unifying VCFs for $1" >> "$report_file"
if [ ! -f "$unify_output" ]; then
	python3 $here_folder/geneyx.analysis.api_CHUSJ/scripts/UnifyVcf/PacBioUnifyVcf.py \
		-o "$directory/$1-unifiedTrioVCFv2.vcf" \
		-s "$3" -r "$2" -c $3 \
		-b $here_folder/geneyx.analysis.api_CHUSJ/scripts/UnifyVcf/STRchive-disease-loci.hg38.TRGT.bed >> "$report_file" 2>&1
fi
if [ -f "$unify_output" ]; then
	echo "Unify ok for $1" >> "$report_file"
else exit 1
fi
echo "$unify_output"
}

#Heredoc to build the samplefiles
function buildSamplefiles() {
	cat << EOF >>$directory/modifiedGeneYXTrio$family_id.json
	{
		"snvVcf": "$3",
		"svVcf": "$2",
		"genomeBuild": "hg38",
		"patientId": "${1}",
		"SampleTarget": "WholeGenomeLR",
		"sampleQcData": "QCData/${family_id}_${1}_QC_new.json",
		"patientGender": "$4",
		"ExcludeFromLAF": "$5",
		"groupAssignmentName": "$group_name",
		"groupAssignmentCode": "$group_code"
	},
EOF
}
#Put the extracted API-ID and pass in the geneyx Config
function geneYXConfig() {
	if [ ! -f $here_folder/../.myGeneYXConf.yml ]; then
		api_ID=$(python3 -c "import json; print(json.load(open('${config_file}'))['GeneYX']['apiUserId'])")
		api_key=$(python3 -c "import json; print(json.load(open('${config_file}'))['GeneYX']['apiUserKey'])")
		sed -e "s,enter-your-userid,$api_ID,g" $here_folder/geneyx.analysis.api_CHUSJ/scripts/ga.config.yml >$here_folder/../.myGeneYXConf.yml
		sed -ie "s,enter-your-userkey,$api_key,g" $here_folder/../.myGeneYXConf.yml

	fi
	ls "$here_folder/../.myGeneYXConf.yml"
}

#Give the dependency list and the function will print a line to be used in sbatch
function dependencyLine() {
	local dependencies=("$@")
	if [ ${#dependencies[@]} -eq 0 ]; then
		local dependencyCallLine=""
	else
		local dependencyCallLine="-d afterok:"
		local IFS=":"
		dependencyCallLine+="${dependencies[*]}"
	fi
	echo "$dependencyCallLine"
}

# Function to pull images before script runs
# I would normally put this in each respective script,but some clusters don't have internet on job nodes
# $1 is imagename $2 is dockerhub
function apptainerGet() {
	if [ -z $APPTAINER_CACHEDIR ]; then
		echo """Warning: You should set an explicit directory for APPTAINER_CACHEDIR in ~/.bashrc IE:
		export APPTAINER_TMPDIR="~/scratch/singularity_cache/tmp"
		export APPTAINER_CACHEDIR="/home/felixant/scratch/singularity_cache"
	"""
		echo "Using script folder for now"
		export APPTAINER_CACHEDIR="$here_folder/apptainer_cache"
		mkdir -p $APPTAINER_CACHEDIR
	fi
	if [ ! -f "$APPTAINER_CACHEDIR/$1" ]; then
		# We have some home-made images that we saved as .def
		if [[ "$2" != *".def"* ]]; then
			apptainer pull $APPTAINER_CACHEDIR/$1 $2
		else
			apptainer build $APPTAINER_CACHEDIR/$1 $2
		fi
	fi
}

#Gathers QC data for all samples
function buildQCData() {
	local stat_file="$directory/_LAST/out/stats_file/$family_id.stats.txt"
	local upstream_folder=$(cd "$directory"/_LAST/call-upstream-"$2"-* ; pwd)
	local bam_reads=$(grep "$1" "$stat_file" | cut -f2)
	local map_reads=$(grep "$1" "$stat_file" | cut -f8)
	local mean_cov=$(grep "$1" "$stat_file" | cut -f12)
	local index=$( expr "$2" + 1 )
	local bam_file=$(grep 'hifi_reads.bc' "$samplesheet" | sed "${index}q;d" | cut -d'"' -f2)
	local bam_directory=$(dirname $(dirname $bam_file)) #/.../1_X01
	local failed_reads=$(grep -w '<Q20 Reads' /"$bam_directory"/statistics/m*.ccs_report.txt | cut -d: -f2 | cut -d' ' -f2 | sed "s/,//g")
	local num_snp=$(grep "$1" "$stat_file" | cut -f22)
	local ratio_hethom=$(grep "$1" "$stat_file" | cut -f24)
	local num_het=$(grep -w '^PSC' "$directory/_LAST/out/small_variant_stats/$2/$1.GRCh38.small_variants.vcf.stats.txt" | cut -f6)
	local num_hom=$(grep -w '^PSC' "$directory/_LAST/out/small_variant_stats/$2/$1.GRCh38.small_variants.vcf.stats.txt" | cut -f5)
	local total_var=$(tail -n 1 "$directory/_LAST/out/phase_stats/$2/$1.GRCh38.hiphase.stats.tsv" | cut -d$'\t' -f3)
	local snv_VCF="$upstream_folder/out/small_variant_vcf/$1.GRCh38.small_variants.vcf.gz"
	local snv_index="$upstream_folder/out/small_variant_vcf_index/$1.GRCh38.small_variants.vcf.gz.tbi"
	local snpY=$(bcftools view -H -r chrY -f PASS "$snv_VCF##idx##$snv_index" | wc -l)
	local snpX=$(bcftools view -H -r chrX -f PASS "$snv_VCF##idx##$snv_index" | wc -l)
	local ratio_xy=$(echo "scale=2;$snpX/$snpY" | bc | sed "s/^\./0\./g")

	local index2=($(($index+1)))
	local mosdepth_dir=$(dirname $(readlink -f $(grep -m 1 -A 3 "humanwgs_family.mosdepth_region_bed" $output_file | sed "${index2}q;d" | cut -d'"' -f2)))
	if [ -f "$mosdepth_dir/thresholdsTable.tsv" ]; then	
		local ratio5X=$(tail -n 1 "$mosdepth_dir/thresholdsTable.tsv" | cut -f1)
		local per5X=$(echo "scale=2;$ratio5X*100" | bc | sed "s/^\./0\./g")
		local message5X="\"Percent5x\": $per5X,"$'\n'$'\t'
		local ratio20X=$(tail -n 1 "$mosdepth_dir/thresholdsTable.tsv" | cut -f2)
		local per20X=$(echo "scale=2;$ratio20X*100" | bc | sed "s/^\./0\./g")
		local message20X="\"Percent20x\": $per20X,"$'\n'$'\t'
		local ratio50X=$(tail -n 1 "$mosdepth_dir/thresholdsTable.tsv" | cut -f3)
		local per50X=$(echo "scale=2;$ratio50X*100" | bc | sed "s/^\./0\./g")
		local message50X="\"Percent50x\": $per50X,"$'\n'$'\t'
	else
		local message5X=""
		local message20X=""
		local message50X=""
	fi

	#QC data
	mkdir -p $SCRATCH/QCData
	>$SCRATCH/QCData/${family_id}_${1}_QC_new.json
	cat << EOF >>"$SCRATCH/QCData/${family_id}_${1}_QC_new.json"
	{
		"sampleSn": "$(basename "${1}")",
		"PassedReadsNum": $bam_reads,
		"FailedReadsNum": $failed_reads,
		"MappedReadsNum": $map_reads,
		"MeanCoverage": $mean_cov,
		$message5X$message20X$message50X"ChrXSnpsCount": $snpX,
		"TotalVariants": $total_var,
		"SnpCount": $num_snp,
		"TotalHeteroCount": $num_het,
		"TotalHomoCount": $num_hom,
		"HetHomRatio": $ratio_hethom,
		"ChrYSnpsCount": $snpY,
		"XySnpsRatio": $ratio_xy
	}

EOF
ls "$SCRATCH/QCData/${family_id}_${1}_QC_new.json"
}

#Generate Plink Ped file if not present
function getPed(){
	if [ ! -f "$directory/${family_id}.ped" ]; then
		echo "Generating .ped Pedigree with Postanalysis/getPed.py"
		python3 "$here_folder/getPed.py" "$family_id" "$samplesheet"
		if [ ! -f "$directory/$family_id.ped" ]; then
			cp "${family_id}.ped" "$directory/" 
		fi
	fi
	if [ ! -f "$directory/${family_id}.ped" ]; then 
		echo "Could not generate PED file" ; exit 1 ; fi
}


#-----Start of Main script------#
family_id=$id

#fasta_path="$SCRATCH/hifi-wdl-resources-v3.1.0/GRCh38/human_GRCh38_no_alt_analysis_set.fasta"
resource_file=$(python3 -c "import json; print(json.load(open('${config_file}'))['Paths']['ref_maps'])")
resource_folder=$(dirname "$resource_file")
tertiary_map=$(python3 -c "import json; print(json.load(open('${config_file}'))['Paths']['tertiary_maps'])")
output_path=$(python3 -c "import json; print(json.load(open('${config_file}'))['Paths']['output_path'])")
fasta_path=$(grep -wm 1 'fasta' "${resource_file}" | cut -f2)
if [ ! -f "$fasta_path" ]; then
	echo "Could not find fasta at $fasta_path"
	exit 1
fi

if [[ -d "$SCRATCH/$family_id" ]]; then
	echo "Directory found at $SCRATCH/$family_id"
	directory="$SCRATCH/$family_id"
elif [[ -d "$output_path/$family_id" ]]; then
	echo "Directory found at $output_path/$family_id"
	directory="$output_path/$family_id"
else
	echo "Directory not found for $family_id"
	exit
fi
if [ -f "$directory/_LAST/outputs.json" ]; then
	output_file="$directory/_LAST/outputs.json"
else
	echo "Could not find outputs.json file in $directory/_LAST/"
	exit
fi

report_file="$directory/R-${id}_$(date +'%Y-%m-%d_%H-%M-%S')_postprocess_report.txt"
echo "Report file is $report_file"
echo "Postprocessing started at $(date) for family $id group $group_name" > "$report_file"
echo "Runall is: $run_all" >> "$report_file"

#Get the haplotagged bams for each sample
for sample in $directory/_LAST/out/merged_haplotagged_bam/*/;do
	sample_dir=$(basename "$sample")	
	if [[ "$sample_dir" == "0" ]]; then
		proband_bam=$(ls "$directory/_LAST/out/merged_haplotagged_bam/$sample_dir/"*GRCh38.haplotagged.bam)
		ln -sf "../../merged_haplotagged_bam_index/0/$(basename "$proband_bam").bai" "$(dirname "$proband_bam")/$(basename "$proband_bam").bai"
		proband_bam_bai=$proband_bam.bai

	elif [[ "$sample_dir" == "1" ]]; then
		first_parent_bam=$(ls "$directory/_LAST/out/merged_haplotagged_bam/$sample_dir/"*GRCh38.haplotagged.bam)
		ln -sf "../../merged_haplotagged_bam_index/1/$(basename "$first_parent_bam").bai" "$(dirname "$first_parent_bam")/$(basename "$first_parent_bam").bai"
		first_parent_bam_bai=$first_parent_bam.bai
	elif [[ "$sample_dir" == "2" ]]; then
		second_parent_bam=$(ls "$directory/_LAST/out/merged_haplotagged_bam/$sample_dir/"*GRCh38.haplotagged.bam)
		ln -sf "../../merged_haplotagged_bam_index/2/$(basename "$second_parent_bam").bai" "$(dirname "$second_parent_bam")/$(basename "$second_parent_bam").bai"
		second_parent_bam_bai=$second_parent_bam.bai
	else
		echo "Role unknown at $sample : $sample_dir"
		exit
	fi 
done

if [ -z "$second_parent_bam" ]; then
	mode="duo"
else
	mode="trio"
fi
echo "Mode set to: $mode" >>$report_file


proband_name=$(cat "$samplesheet" | grep  '"sample_id": ' | cut -d'"' -f4 | head -n 1)
echo "Proband name: $proband_name" >>$report_file
first_parent_name=$(cat "$samplesheet" | grep  '"sample_id": ' | cut -d'"' -f4 | sed '2q;d')
echo "First parent name: $first_parent_name" >>$report_file
if [ "$mode" == "duo" ]; then second_parent_name="null"
else second_parent_name=$(cat "$samplesheet" | grep  '"sample_id": ' | cut -d'"' -f4 | sed '3q;d')
	echo "second_parent name: $second_parent_name" >>$report_file
fi

# Variant paths
proband_small_variant=$(ls $directory/_LAST/out/phased_small_variant_vcf/0/$proband_name.$family_id.joint.*.vcf.gz)
proband_TRGT=$(ls $directory/_LAST/out/phased_trgt_vcf/0/$proband_name.*.vcf.gz)
proband_SV=$(ls $directory/_LAST/out/phased_sv_vcf/0/$proband_name.$family_id.joint.*.vcf.gz)
first_parent_small_variant=$(ls $directory/_LAST/out/phased_small_variant_vcf/1/$first_parent_name.$family_id.joint.*.vcf.gz)
first_parent_TRGT=$(ls $directory/_LAST/out/phased_trgt_vcf/1/$first_parent_name.*.vcf.gz)
first_parent_SV=$(ls $directory/_LAST/out/phased_sv_vcf/1/$first_parent_name.$family_id.joint.*.vcf.gz)

if [ "$mode" == "duo" ]; then
	second_parent_small_variant="null"
	second_parent_TRGT="null"
	second_parent_SV="null"
else
	second_parent_small_variant=$(ls $directory/_LAST/out/phased_small_variant_vcf/2/$second_parent_name.$family_id.joint.*.vcf.gz)
	second_parent_TRGT=$(ls $directory/_LAST/out/phased_trgt_vcf/2/$second_parent_name.*.vcf.gz)
	second_parent_SV=$(ls $directory/_LAST/out/phased_sv_vcf/2/$second_parent_name.$family_id.joint.*.vcf.gz)
fi

#We normalize the small variant vcfs before sending them to GeneYX
echo "Normalizing variants"
proband_normalized_SNV=$(Normalize "$proband_name" "$proband_small_variant")
first_parent_normalized_SNV=$(Normalize "$first_parent_name" "$first_parent_small_variant")
if [ "$mode" == "duo" ]; then second_parent_normalized_SNV="null"
else second_parent_normalized_SNV=$(Normalize "$second_parent_name" "$second_parent_small_variant")
fi

#Unify the 4 different VCFs into one for each sample
echo "Unifying variants"
proband_unified_vcf=$(UnifyVCF "$proband_name" "$proband_TRGT" "$proband_SV")
first_parent_unified_vcf=$(UnifyVCF "$first_parent_name" "$first_parent_TRGT" "$first_parent_SV")
if [ "$mode" == "duo" ]; then second_parent_unified_vcf="null"
else second_parent_unified_vcf=$(UnifyVCF "$second_parent_name" "$second_parent_TRGT" "$second_parent_SV")
fi

# ===== Gender Check =====
# Proband
real_gender=$(grep -m1 '"sex": ' "$samplesheet" | cut -d'"' -f4)
inferred_gender=$(grep -A 3 humanwgs_family.inferred_sex $output_file | sed "2q;d" | cut -d\" -f2)

# Check the first parent (usually the mother)
first_parent_real_gender=$(grep -m2 '"sex": ' "$samplesheet" | sed -n '2p' | cut -d'"' -f4)
first_parent_inferred_gender=$(grep -A 3 humanwgs_family.inferred_sex $output_file | sed "3q;d" | cut -d\" -f2)
if [ "$first_parent_real_gender" == "FEMALE" ]; then
	first_parent_role="Mother"
elif [ "$first_parent_real_gender" == "MALE" ]; then
	first_parent_role="Father"
else
	echo "Warning: First parent's given gender is not recognized: $first_parent_real_gender"
	exit 1
fi

# If present, check the second parent (usually the father)
if [ "$mode" == "trio" ]; then
	second_parent_real_gender=$(grep -m3 '"sex": ' "$samplesheet" | sed -n '3p' | cut -d'"' -f4)
	second_parent_inferred_gender=$(grep -A 3 humanwgs_family.inferred_sex $output_file | sed "4q;d" | cut -d\" -f2)

	if [ "$second_parent_real_gender" == "MALE" ]; then
		second_parent_role="Father"
	elif [ "$second_parent_real_gender" == "FEMALE" ]; then
		second_parent_role="Mother"
	else
		echo "Warning: Second parent's given gender is not recognized: $second_parent_real_gender"
		exit 1
	fi
fi

# Check specifically for errors in assigned and inferred genders
genderError=false
if [ "$first_parent_inferred_gender" != "$first_parent_real_gender" ]; then
	echo "Warning: First parent's (Of assigned role $first_parent_role) inferred gender is not $first_parent_real_gender:  Got $first_parent_inferred_gender"
	genderError=true
fi

if [ "$second_parent_inferred_gender" != "$second_parent_real_gender" ]; then
	echo "Warning: Second parent's (Of assigned role $second_parent_role) inferred gender is not $second_parent_real_gender:  Got $second_parent_inferred_gender"
	genderError=true
fi

if [ "$real_gender" = "null" ] && [ "$inferred_gender" = "null" ];then
	echo "Warning: gender is set to 'null'"
	final_gender=""
else
	if [ "$real_gender" = "$inferred_gender" ];then
		echo "Proband Gender confirmed to be $real_gender" >> $report_file
		final_gender=$(echo $real_gender | cut -c1-1)
	elif [ "$real_gender" = "null" ];then
		echo "Real gender was null, using inferred gender: $inferred_gender" >> $report_file
		final_gender=$(echo "$inferred_gender" | cut -c1-1)
	elif [ "$inferred_gender" = "null" ];then
		echo "Inferred gender was null, using given gender: $real_gender" >> $report_file
		final_gender=$(echo "$real_gender" | cut -c1-1)
	else
		echo "Warning: Given gender ($real_gender) does not fit inferred gender ($inferred_gender)." >> $report_file
		final_gender=$(echo "$real_gender" | cut -c1-1)
		genderError=true
	fi
fi

if [ "$mode" == "trio" ] && [ "$second_parent_role" == "$first_parent_role" ]; then
	echo "Warning: Both parents have the same assigned role of $first_parent_role"
	genderError=true
fi

if [ "$genderError" == "true" ]; then echo "Found gender error, Exiting"; exit 1
fi


#-----Steps-----#

if [ $run_all == true ]; then
	echo "Running all steps without prompt"
else
	echo "Interactive mode enabled, will prompt for each step"
	ask_yes_no "Send to GeneYX?" send_to_geneyx
	ask_yes_no "Send Case to GeneYX?" send_case_to_geneyx
	ask_yes_no "Send QC info to GeneYX?" send_qc_to_geneyx
	ask_yes_no "Include SVTopo?" include_svtopo
	ask_yes_no "Include TrioMix?" include_triomix
	ask_yes_no "Include Somalier?" include_somalier
	ask_yes_no "Include PEDDY?" include_peddy
	ask_yes_no "Include MultiQC?" include_multiqc
	ask_yes_no "Include cleanup and send?" include_cleanup

fi

#Send to GeneYX step
if [ "$send_to_geneyx" == true ] || [ "$run_all" == true ]; then
	loadEnv "GeneYX_env"
	my_config=$(geneYXConfig)
	#Building the JSON file for GeneYX upload
	printf "{\n\t\"samples\": [\n\t" >$directory/modifiedGeneYXTrio$family_id.json

	#Heredocs for iterative file building
	buildSamplefiles "$proband_name" "$(basename "$proband_unified_vcf")" "$(basename "$proband_normalized_SNV")" "$final_gender" "True"
	buildSamplefiles "$first_parent_name" "$(basename "$first_parent_unified_vcf")" "$(basename "$first_parent_normalized_SNV")" "F" "False"
	if [ "$mode" == "duo" ]; then echo "Skipping second_parent, duo mode"
	else buildSamplefiles "$second_parent_name" "$(basename "$second_parent_unified_vcf")" "$(basename "$second_parent_normalized_SNV")" "M" "False"
	fi
	#Remove comma from last line
	sed -i '$ s/},/}/' "$directory/modifiedGeneYXTrio$family_id.json"
	printf "\t]\n}" >>$directory/modifiedGeneYXTrio$family_id.json
	echo JSON file for GeneYX upload built: $directory/modifiedGeneYXTrio$family_id.json >> "$report_file"
	cat $directory/modifiedGeneYXTrio$family_id.json >> "$report_file"
	cd $directory
	python3 $here_folder/geneyx.analysis.api_CHUSJ/scripts/JSON_Sample_Upload.py \
		--jsonFile $directory/modifiedGeneYXTrio$family_id.json \
		-c $my_config 2>> "$report_file" 2>&1
	echo "Sample upload to GeneYX done......................" >> "$report_file"
fi

#Send Case to GeneYX step
if [ "$send_case_to_geneyx" == true ] || [ "$run_all" == true ]; then
	loadEnv "GeneYX_env"
	my_config=$(geneYXConfig)
	hpoTerms=$(jq -r '.["humanwgs_family.phenotypes"]' "$(dirname $output_file)/inputs.json")
	if [ "$mode" == "duo" ]; then
		second_parentDesc=""
		second_parentString=""
	else
		second_parentDesc="and $second_parent_role: $second_parent_name"
		second_parentString=",
				{
				\"Relation\": \"$second_parent_role\",
				\"SampleId\": \"${second_parent_name}\",
				\"Affected\": \"Unaffected\"
				}"
	fi
	echo "building Case upload file"
	>$directory/modifiedTrioCaseUpload$family_id.json
	cat << EOF >>$directory/modifiedTrioCaseUpload$family_id.json
	{
		"ProtocolId": "LR_Trio",
		"Name": "${proband_name}_${mode}_${family_id}",
		"Description": "$mode analysis for FamilyID: $family_id, composed of proband: $proband_name, $first_parent_role: $first_parent_name $second_parentDesc",
		"SubjectId": "${proband_name}",
		"Phenotypes": "$hpoTerms",
		"ProbandSampleId": "${proband_name}",
		"AssociatedSamples": [ 
			{
			"Relation": "$first_parent_role",
			"SampleId": "$first_parent_name",
			"Affected": "Unaffected"
			}$second_parentString
		]
	}
EOF
	echo "Case upload JSON file built: $directory/modifiedTrioCaseUpload$family_id.json" >> "$report_file"
	cat $directory/modifiedTrioCaseUpload$family_id.json >> "$report_file"
	cd  $directory
	python3 $here_folder/geneyx.analysis.api_CHUSJ/scripts/ga_CreateCase.py \
		--data $directory/modifiedTrioCaseUpload$family_id.json \
		-c $my_config 2>> "$report_file" 2>&1
	echo "Case upload to GeneYX done......................" >> "$report_file"

fi

#Send QC Data to GeneYX step
if [ "$send_qc_to_geneyx" == true ] || [ "$run_all" == true ]; then
	loadEnv "GeneYX_env"
	my_config=$(geneYXConfig)
	#Building the JSON file for GeneYX upload
	echo "Retrieving QC data for proband..." >> "$report_file"
	probandQCData=$(buildQCData "$proband_name" "0" "$(basename $proband_normalized_SNV)")
	cat "$probandQCData" >> "$report_file"

	echo "Retrieving QC data for $first_parent_role..." >> "$report_file"
	first_parentQCData=$(buildQCData "$first_parent_name" "1" "$(basename $first_parent_normalized_SNV)")
	cat "$first_parentQCData" >> "$report_file"
	python3 $here_folder/geneyx.analysis.api_CHUSJ/scripts/ga_addQcData.py -d "$probandQCData" -c $my_config 2>> "$report_file" 2>&1
	python3 $here_folder/geneyx.analysis.api_CHUSJ/scripts/ga_addQcData.py -d "$first_parentQCData" -c $my_config 2>> "$report_file" 2>&1
	if [[ $mode == "duo" ]]; then
		echo "Skipping second_parent, duo mode" >> "$report_file"
	else
		echo "Retrieving QC data for second_parent..." >> "$report_file"
		second_parentQCData=$(buildQCData "$second_parent_name" "2" "$(basename $second_parent_normalized_SNV)")
		cat "$second_parentQCData" >> "$report_file"
		python3 $here_folder/geneyx.analysis.api_CHUSJ/scripts/ga_addQcData.py -d "$second_parentQCData" -c $my_config 2>> "$report_file" 2>&1
	fi
	echo "QC data upload to GeneYX done...................." >> "$report_file"
fi

#Initializes a list of dependencies as slurm-id of sbatch jobs
#This will make sure that steps are run in order
dependencies=()
echo "Launch step time"
#SVTopo step
if [ "$include_svtopo" == true ] || [ "$run_all" == true ]; then
	cp $tools_folder/SVTopo/svtopo_requirements.txt $APPTAINER_CACHEDIR/
	apptainerGet "svtopo_v0.3.0.sif" $tools_folder/SVTopo/svtopo.def
	supporting_reads="$directory/_LAST/out/sv_supporting_reads/${family_id}.joint.GRCh38.structural_variants.supporting_reads.json.gz"
	
	echo "Launching SVTopo with Scripts/svtopocall_from_image.sh" >> "$report_file"
	dependency_Proband="$(sbatch --parsable -J svtopo_${family_id}_proband \
		-D $directory/SVTOPO_OUTPUTS $tools_folder/SVTopo/svtopocall_from_image.sh \
		-p "$family_id-proband-${proband_name}" -b "$proband_bam" -i "$proband_bam_bai" \
		-s "$supporting_reads" -v "$proband_SV" -r "$resource_folder" -o $directory -t $tools_folder)"
	echo "Find SVTopo report for proband: $directory/SVTOPO_OUTPUTS/J-svtopo_${family_id}_proband.$dependency_Proband.out" >> "$report_file"
	dependency_first_parent="$(sbatch --parsable -J svtopo_${family_id}_$first_parent_role \
		-D $directory/SVTOPO_OUTPUTS $tools_folder/SVTopo/svtopocall_from_image.sh \
		-p "$family_id-$first_parent_role-${first_parent_name}" -b "$first_parent_bam" -i "$first_parent_bam_bai" \
		-s "$supporting_reads" -v "$first_parent_SV" -r "$resource_folder" -o $directory -t $tools_folder)"
	echo "Find SVTopo report for $first_parent_role: $directory/SVTOPO_OUTPUTS/J-svtopo_${family_id}_$first_parent_role.$dependency_first_parent.out" >> "$report_file"
	dependencies+=("$dependency_Proband" "$dependency_first_parent")
	if [ "$mode" == "trio" ]; then
		dependency_second_parent="$(sbatch --parsable -J svtopo_${family_id}_$second_parent_role \
			-D $directory/SVTOPO_OUTPUTS $tools_folder/SVTopo/svtopocall_from_image.sh \
			-p "$family_id-$second_parent_role-${second_parent_name}" -b "$second_parent_bam" -i "$second_parent_bam_bai" \
			-s "$supporting_reads" -v "$second_parent_SV" -r "$resource_folder" -o $directory -t $tools_folder)"
		echo "Find SVTopo report for $second_parent_role: $directory/SVTOPO_OUTPUTS/J-svtopo_${family_id}_$second_parent_role.$dependency_second_parent.out" >> "$report_file"
		dependencies+=("$dependency_second_parent")
	fi
fi

#Triomix step
if [ "$include_triomix" == true ] || [ "$run_all" == true ]; then
	if [ "$mode" == "trio" ]; then
		apptainerGet "triomix_v0.0.2.sif" "docker://cjyoon/triomix:v0.0.2"
		cd "$directory"
		echo "Launching Triomix" >> "$report_file"
		mkdir -p Triomix_analyses
		dependency_Triomix="$(sbatch --parsable -J triomix_${family_id} \
			-D $directory/Triomix_analyses $tools_folder/Triomix/triomixcall_from_image.sh \
			-p "$proband_bam" -m "$first_parent_bam" -f "$second_parent_bam" -r "$fasta_path" -o "$directory")"
		echo "Find Triomix report at $directory/Triomix_analyses/J-triomix_${family_id}.$dependency_Triomix.out" >> "$report_file"
		dependencies+=("$dependency_Triomix")
	else
		echo "TrioMix is meant for trio analysis, skipping for duo mode" >> "$report_file"
	fi
fi

#Somalier step
if  [ "$run_all" == true ] || [ "$include_somalier" == true ]; then
	apptainerGet somalier-v0.3.1.sif docker://brentp/somalier:v0.3.1

	#Some extra prerequisites for Ancestry
	if [ ! -f "$APPTAINER_CACHEDIR/1kg.somalier.tar.gz" ]; then
		echo "Downloading 1-kg somalier data"
		wget https://zenodo.org/record/3479773/files/1kg.somalier.tar.gz -O "$APPTAINER_CACHEDIR/1kg.somalier.tar.gz"
	fi
	if [ ! -d "$APPTAINER_CACHEDIR/1kg-somalier" ]; then
		tar -xzf "$APPTAINER_CACHEDIR/1kg.somalier.tar.gz" -C "$APPTAINER_CACHEDIR/"
	fi
	
	getPed
	cd "$directory"
	echo "Launching Somalier" >> "$report_file"
	dependency_Somalier="$(sbatch --parsable -J somalier_${family_id} \
		-D $directory/Somalier_analyses $tools_folder/Somalier/somaliercall_from_image.sh \
		-p "$proband_name" -1 "$first_parent_name" -2 "$second_parent_name" \
		-r $fasta_path -i $family_id -d "$directory" -s $tools_folder/Somalier/sites.hg38.vcf.gz)"
	echo "Find Somalier report at $directory/Somalier_analyses/J-somalier_${family_id}.$dependency_Somalier.out" >> "$report_file"
	dependencies+=($dependency_Somalier)
	cd "$here_folder"
fi

#Peddy step
if [ "$include_peddy" == true ] || [ "$run_all" == true ]; then
	cp $tools_folder/Peddy/peddy_requirements.txt $APPTAINER_CACHEDIR/
	apptainerGet peddy_v0.4.8.sif $tools_folder/Peddy/peddy.def
	getPed
	cd "$directory"
	echo "running PEDDY for merged.$family_id.normed.joint.GRCh38.small_variants.phased.merged.vcf.gz" >> "$report_file"
	dependency_Peddy="$(sbatch --parsable -J peddy_${family_id} \
		-D $directory/Peddy_analyses $tools_folder/Peddy/peddycall_from_image.sh \
		-p "$proband_name" -1 "$first_parent_name" -2 "$second_parent_name" -i $family_id -d "$directory")"
	echo "Find Peddy report at $directory/Peddy_analyses/J-peddy_${family_id}.$dependency_Peddy.out" >> "$report_file"
	dependencies+=($dependency_Peddy)
fi

#MultiQC step
final_dependencies=()
if [ "$include_multiqc" == true ] || [ "$run_all" == true ]; then
	cd "$directory"
	apptainerGet multiqc_v1.3.3.sif docker://multiqc/multiqc:v1.33
	dependency_Call_Line=$(dependencyLine "${dependencies[@]}")
	echo "dependency line for multiqc: $dependency_Call_Line" >> "$report_file"
	#I use an sbatch so we can use job dependencies and run this AFTER the other steps
	dependency_MultiQC=$(sbatch $dependency_Call_Line --parsable -J multiqc_${family_id} \
		-D $directory $tools_folder/MultiQc/multiQccall_from_image.sh)
	echo "Find MultiQC report at $directory/J-multiqc_${family_id}.$dependency_MultiQC.out" >> "$report_file"
	final_dependencies+=("$dependency_MultiQC")
fi

#Cleanup and transfer step
if [ "$include_cleanup" == true ] || [ "$run_all" == true ]; then
	bash $here_folder/cleanup.sh -i $family_id -d $directory -c $config_file
	bash $here_folder/outputs_Json.sh -i $family_id -d $directory -c $config_file
	bash $here_folder/send_Symlinks_Narval.sh -i $family_id -d $directory -c $config_file -r

	loadEnv "Globus_env"
	#flow=6336492e-e308-4a67-b78e-13684c747472 # move and delete flow
	destination_endpoint="$(jq -r '.Transfers.destination_endpoint' "${config_file}")" # Narval endpoint UUID
	destination_collection="$(jq -r '.Transfers.destination_collection' "${config_file}")" # Narval collection UUID
	source_endpoint="$(jq -r '.Transfers.working_endpoint' "${config_file}")"
	source_collection="$(jq -r '.Transfers.working_collection' "${config_file}")"
	if [ -z "$source_endpoint" ] || [ -z "$destination_endpoint" ]; then
		echo "Given cluster endpoint for origin or destination not found."
		exit 1
	fi
	globus login --gcs ${destination_endpoint}:${destination_collection} --gcs ${source_endpoint}:${source_collection}
	# cluster=$(jq -r '.Transfers.cluster_name' "${config_file}")
	# if [ "$cluster" == "Fir" ] || [ "$cluster" == "fir" ]; then
	# 	echo "sbatch $final_job_line -J Globus_$family_id $here_folder/globus_cli_send.sh -i $family_id -d $directory -c $config_file -h $here_folder"
	# 	sbatch "$final_job_line" -J Globus_$family_id "$here_folder/globus_cli_send.sh" -i "$family_id" -d "$directory" -c "$config_file" -h "$here_folder"
	# 	exit 0
	# else

	#If ready to send, we can append to the final list (used for updating BAMs to the correct sample)
	echo "$proband_name,$family_id/proband/${proband_name}" >>"$here_folder/geneYXNameList.txt"
	echo "$first_parent_name,$family_id/${first_parent_role,,}/${first_parent_name}" >>"$here_folder/geneYXNameList.txt"
	echo "$second_parent_name,$family_id/${second_parent_role,,}/${second_parent_name}" >>"$here_folder/geneYXNameList.txt"
	destination_path="$(jq -r '.Transfers.destination_path' $config_file)"
	#echo "globus transfer --label $family_id-transfer -r "${source_collection}:$directory" "${destination_collection}:${destination_path}/$family_id""
	
	#globus transfer --label $family_id-transfer -r "${source_collection}:$directory" "${destination_collection}:${destination_path}/$family_id"

	#Normally, as long as we launch after multiqc (and cleanup), every step should have been done
	final_dependency_line=$(dependencyLine "${final_dependencies[@]}")
	echo "dependency line for Cleanup: $final_dependency_line"
	sbatch $final_dependency_line -D $directory -J final_globus_${family_id} "$here_folder/globus_cli_send.sh" -i "$family_id" -d "$directory" -c "$config_file" -t "$tools_folder"

fi
	exit 0
