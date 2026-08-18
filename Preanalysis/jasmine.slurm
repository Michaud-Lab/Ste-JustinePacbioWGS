#!/bin/bash
#
#SBATCH --time=24:00:00
#SBATCH --account=def-rallard
#SBATCH --output=J-%x.%j.out
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --tmp=600G

set -eo pipefail
#Argument 1 is MOVIE.bcXXXX.consensusreadset.xml
#Argument 2 (optional) is the pbjasmine version to run, e.g. 2.4.0 - see JASMINE_TAGS below
#for the known versions and the exact quay.io/biocontainers tag each maps to. Defaults to
#$DEFAULT_JASMINE_VERSION if omitted - jasmine has a hard-coded list of sequencing chemistries
#it recognizes as supported, so a BAM from newer basecaller/kit combinations may need a newer
#version than the default (see quay.io/biocontainers/pbjasmine/tags for available tags).

#YOU MUST PROVIDE THE FULL ABSOLUTE PATH
#example call:
#sbatch -D /home/felixant/links/projects/rrg-rallard/shared/PacBioDataRorqual/SequencerData/r84196_20251010_130733/1_B01/pb_formats jasmine.slurm -x /home/felixant/links/projects/rrg-rallard/shared/PacBioDataRorqual/SequencerData/r84196_20251010_130733/1_B01/pb_formats/m84196_251010_201413_s3.hifi_reads.bc2090.consensusreadset.xml -t 2.4.0
declare -A JASMINE_TAGS=(
  ["2.0.0"]="2.0.0"
  ["2.4.0"]="2.4.0"
  ["2.7.99"]="2.7.99"
  ["26.1.2"]="26.1.2"
  ["26.1.3"]="26.1.3"
)


: "${SLURM_TMPDIR:?SLURM_TMPDIR is not set - this script must run inside a Slurm job}"

usage() {
    echo "Usage: $0 -x <consensusreadset.xml> [-t <jasmine_version>] [-c <config_file>]" 1>&2
    exit 1
}
JASMINE_VERSION="2.0.0"
JASMINE_TAG="${JASMINE_TAGS[$JASMINE_VERSION]:-}"
config_file="$SCRATCH/Ste-JustinePacbioWGS/.myconf.json"
while getopts "x:t:c:" opt; do
    case "${opt}" in
		x)	INXML="${OPTARG}"
			if [ ! -f "$INXML" ]; then
				echo "XML file not found"
				usage
			fi
			prefix=$(basename "$INXML" .consensusreadset.xml)
			pbDir=$(dirname "$INXML")
			;;
        t)  JASMINE_VERSION="${OPTARG}"
			JASMINE_TAG="${JASMINE_TAGS[$JASMINE_VERSION]:-}"
            ;;
        c)  config_file="${OPTARG}" ;;
        :)  echo "Error: -${OPTARG} requires an argument."; usage ;;
        *)  usage ;;
    esac
done
shift $((OPTIND-1))

if [ -z "${INXML:-}" ]; then
	echo "Error: -x <consensusreadset.xml> is required." >&2
	usage
fi


if [ -z "$JASMINE_TAG" ]; then
  echo "Unknown pbjasmine version '$JASMINE_VERSION'. Known versions: ${!JASMINE_TAGS[*]}" >&2
  exit 1
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

wgs_folder=$(jq -r '.Paths.WGS_folder' "$config_file")
tools_folder="$wgs_folder/Tools"
if [ ! -d "$tools_folder" ]; then
	echo "Tools folder in run folder $wgs_folder not found, please put it in config file, under 'Path/WGS_folder'"
	exit 1
fi

outxml="$pbDir/$prefix.jasmine.consensusreadset.xml"
cp -v "$INXML" "$outxml"
echo "INXML $(basename "$INXML")"
echo "OUTXML $(basename "$outxml")"

echo "Using pbjasmine version $JASMINE_VERSION (tag $JASMINE_TAG)"
JASMINE_DIR="$tools_folder/Jasmine_$JASMINE_TAG"

#download if necessary
if [ ! -f "$JASMINE_DIR/jasmine" ]; then
	mkdir -p "$JASMINE_DIR"
	# This tag specifically is not tarred
	if [ "$JASMINE_TAG" == "2.0.0" ]; then
		wget -P "$JASMINE_DIR" https://github.com/PacificBiosciences/jasmine/releases/download/v2.0.0/jasmine
	else
		wget -P "$JASMINE_DIR" https://github.com/PacificBiosciences/jasmine/releases/download/v${JASMINE_TAG}/jasmine.tar.xz
		tar -xf "$JASMINE_DIR/jasmine.tar.xz" -C "$JASMINE_DIR"
	fi
fi

cp -v "$JASMINE_DIR/jasmine" "$SLURM_TMPDIR/jasmine"
THREADS=${SLURM_CPUS_PER_TASK:-3}
chmod +x "$SLURM_TMPDIR/jasmine"
# Jasmine calls 5mC in CpG motifs. This only works for BAMs with kinetics data.
"$SLURM_TMPDIR/jasmine" --version

out_bams=()
for readType in "ConsensusReadBamFile:hifi_reads" "FailReadBamFile:fail_reads"; do
	metaType=${readType%%:*}
	dirName=${readType##*:}

	# Extract relative path in xml
	rel=$(grep -oP "MetaType=\"PacBio\.ConsensusReadFile\.${metaType}\"[^>]*ResourceId=\"\K[^\"]+\.bam" "$INXML")
	echo "Readtype: $readType"
	echo "Rel: $rel"
	#unassigned_rel=${rel/$barcode/unassigned}
	in_bam=$(realpath -m "$pbDir/$rel") #$(realpath -m "$pbDir/$unassigned_rel")
	in_base=$(basename "$in_bam")
	out_base="${in_base%.bam}.jasminev2.bam"

	ls -lah "$SLURM_TMPDIR"
	[ -f "$in_bam.pbi" ] && cp -v "$in_bam.pbi" "$SLURM_TMPDIR/$in_base.pbi"
	
	# If jasmine version is 2.0.0, it will not work with SPRQ chemistry.
	# We need to replace the BINDINGKIT and SEQUENCINGKIT in BAM header
	# jasmine itself removes any existing MM/ML tags before inference, so no
	# separate tag-stripping pass is needed here.
	if [ "$JASMINE_TAG" == "2.0.0" ]; then
		module load samtools/1.22.1
		# Header files live in $SLURM_TMPDIR, not next to $in_bam: that source
		# directory is shared/read-only PacBioData storage, not guaranteed writable.
		new_header_file="$SLURM_TMPDIR/header_$(basename "$in_bam" .bam)_new.txt"
		samtools view -H "$in_bam" | \
			sed "s/BINDINGKIT=103-496-900;SEQUENCINGKIT=103-496-700/BINDINGKIT=102-739-100;SEQUENCINGKIT=102-118-800/" \
			> "$new_header_file"
		echo "Changing headers for input bam $in_base"
		# The reheader can only be performed in-place with CRAMs, not BAMs
		samtools reheader "$new_header_file" "$in_bam" > "$SLURM_TMPDIR/$in_base"
	else
		echo "Copying $in_base to scratch"
		cp -v "$in_bam" "$SLURM_TMPDIR/$in_base"
	fi
	echo "Running Jasmine command:"
	cat << EOF
"$SLURM_TMPDIR"/jasmine \
-j "$THREADS" \
--log-level DEBUG \
--log-file "$pbDir/jasmine.$dirName.log" \
"$SLURM_TMPDIR/$in_base" \
"$SLURM_TMPDIR/$out_base"
EOF
	"$SLURM_TMPDIR"/jasmine \
		-j "$THREADS" \
		--log-level DEBUG \
		--log-file "$pbDir/jasmine.$dirName.log" \
		"$SLURM_TMPDIR/$in_base" \
		"$SLURM_TMPDIR/$out_base"

	echo "Copying results back for $dirName"
	#mv -v "$SLURM_TMPDIR/jasmine.$dirName.log" "$pbDir/jasmine.$dirName.log"
	cp -v "$SLURM_TMPDIR/$out_base" "$pbDir/$out_base"
	[ -f "$SLURM_TMPDIR/$out_base.pbi" ] && cp -v "$SLURM_TMPDIR/$out_base.pbi" "$pbDir/$out_base.pbi"

	# Point the output XML at the new local (same-directory) jasmine BAM instead of the old
	# ../$dirName/ path, so it no longer resolves outside of $pbDir.
	sed -i "s,ResourceId=\"\.\./${dirName}/${in_base}\",ResourceId=\"./${out_base}\",g; s,ResourceId=\"\.\./${dirName}/${in_base}\.pbi\",ResourceId=\"./${out_base}\.pbi\",g" "$outxml"

	# Free scratch space before the next read type
	rm -f "$SLURM_TMPDIR/$in_base" "$SLURM_TMPDIR/$in_base.pbi" "$SLURM_TMPDIR/$out_base" "$SLURM_TMPDIR/$out_base.pbi"
	out_bams+=("$pbDir/$out_base")
done

# Only reached if every step above succeeded (set -e). run_jasmine.sh checks for this marker
# to skip cells that were already successfully processed with this jasmine version.
touch "$pbDir/.jasmine_${JASMINE_VERSION}.done"
echo "Marked $pbDir as done for jasmine $JASMINE_VERSION"
