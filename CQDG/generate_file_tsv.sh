#!/bin/bash

# Generates file.tsv: one row per deliverable file symlinked under
# CQDG_Deliverables/$famille_decodeur, for CQDG submission.
#
# Walks the same Famille -> Famille_Decodeur grouping and CQDG_files_v*.tsv
# naming templates as create_cqdg_symlinks.sh (run that first), but instead of
# creating symlinks it reads the ones already there and, for each that exists,
# emits: study_id, submitter_sample_id, analysis_name, submitter_file_name,
# file_size, file_md5sum, file_type, data_type.
#
# analysis_name is "WGS-WDL_v<Version>", where <Version> is the Version column
# from Decodeur_list_updated.tsv for that file's pipeline run (Famille) — this
# also picks which CQDG_files_v*.tsv supplies file_type/data_type.
# submitter_sample_id is the sample ID for sample-scope files, or the
# proband's sample ID (read from OutputFamilies/$raw_family/$raw_family.ped,
# the row with phenotype==2) for family-scope files (joint/merged VCFs).
#
# MD5s are cached by (resolved path, size, mtime) in .md5_cache.tsv next to
# this script — the underlying data is multiple TB, so re-hashing everything
# on every run (this is meant to be run occasionally, as new families land)
# would be far too slow. A first full run can still take a long time; run it
# in the background (nohup/sbatch) rather than waiting on it interactively.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
decodeur_list="$script_dir/Decodeur_list_updated.tsv"
out_tsv="$script_dir/file.tsv"
md5_cache="$script_dir/.md5_cache.tsv"

source_base="/home/felixant/projects/ctb-rallard/COMMUN/PacBioData/OutputFamilies"
dest_base="/home/felixant/projects/ctb-rallard/COMMUN/PacBioData/CQDG_Deliverables"

study_id="DECODEUR"
s3_bucket="cqdg-staging://chusj-decodeur-staging-sd4h"

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Map a Decodeur_list_updated.tsv "Version" value to its CQDG file-naming
# template — same buckets as create_cqdg_symlinks.sh's tsv_for_version.
tsv_for_version() {
    case "$1" in
        2.0) echo "$script_dir/CQDG_files_v2.0.tsv" ;;
        3.0|3.1) echo "$script_dir/CQDG_files_v3.1-v3.0.tsv" ;;
        3.2) echo "$script_dir/CQDG_files_v3.2.tsv" ;;
        *) echo "" ;;
    esac
}

# --- Parse Decodeur_list_updated.tsv ---
declare -A family_samples
declare -A decodeur_members
declare -a decodeur_order
declare -A raw_family_version

while IFS=$'\t' read -r raw_family famille_decodeur id cell barcode run sexe type_famille version; do
    [ -z "$raw_family" ] && continue

    if [ -z "${family_samples[$raw_family]+x}" ]; then
        family_samples[$raw_family]="$id"
    else
        case " ${family_samples[$raw_family]} " in
            *" $id "*) ;;
            *) family_samples[$raw_family]="${family_samples[$raw_family]} $id" ;;
        esac
    fi

    if [ -z "${decodeur_members[$famille_decodeur]+x}" ]; then
        decodeur_members[$famille_decodeur]="$raw_family"
        decodeur_order+=("$famille_decodeur")
    else
        case " ${decodeur_members[$famille_decodeur]} " in
            *" $raw_family "*) ;;
            *) decodeur_members[$famille_decodeur]="${decodeur_members[$famille_decodeur]} $raw_family" ;;
        esac
    fi

    raw_family_version[$raw_family]="$(trim "$version")"
done < <(tail -n +2 "$decodeur_list"; printf '\n')

# --- Load file templates (file_name, file_type, data_type, scope) ---
declare -a tpl_names
declare -a tpl_types
declare -a tpl_data_types
declare -a tpl_scopes

load_templates() {
    local tsv="$1"
    tpl_names=()
    tpl_types=()
    tpl_data_types=()
    tpl_scopes=()
    while IFS=$'\t' read -r file_name file_type data_type scope description outname; do
        file_name="$(trim "$file_name")"
        file_type="$(trim "$file_type")"
        data_type="$(trim "$data_type")"
        scope="$(trim "$scope")"
        [ -z "$file_name" ] && continue
        tpl_names+=("$file_name")
        tpl_types+=("$file_type")
        tpl_data_types+=("$data_type")
        tpl_scopes+=("$scope")
    done < <(tail -n +2 "$tsv"; printf '\n')
}

# Proband sample ID for a raw_family, from its top-level PED file
# (OutputFamilies/$raw_family/$raw_family.ped: family_id, individual_id,
# paternal_id, maternal_id, sex, phenotype — the proband is phenotype==2).
# A run under an internal alias (e.g. "p041WFailed") names its PED file after
# that alias instead — if the exact name is missing, fall back to the one
# *.ped file directly in that family's directory (ignoring Peddy_analyses/,
# whose .ped has a different, extended format).
# Falls back to the fam_decodeur id, with a warning, if none of that works.
find_proband() {
    local raw_family="$1" fam_decodeur="$2"
    local ped="$source_base/$raw_family/$raw_family.ped"
    local proband=""
    if [ ! -f "$ped" ]; then
        mapfile -t ped_candidates < <(find "$source_base/$raw_family" -maxdepth 1 -iname "*.ped" 2>/dev/null)
        [ "${#ped_candidates[@]}" -eq 1 ] && ped="${ped_candidates[0]}"
    fi
    if [ -f "$ped" ]; then
        proband="$(awk -F'\t' '$6==2 {print $2; exit}' "$ped")"
    fi
    if [ -z "$proband" ]; then
        echo "WARNING: $raw_family (decodeur=$fam_decodeur): could not determine proband from $ped — family-scope rows will use '$fam_decodeur' as submitter_sample_id instead" >&2
        proband="$fam_decodeur"
    fi
    printf '%s' "$proband"
}

# --- MD5 cache: resolved path -> "size\tmtime\tmd5" ---
declare -A md5_cache_data
if [ -f "$md5_cache" ]; then
    while IFS=$'\t' read -r path size mtime md5; do
        [ -z "$path" ] && continue
        md5_cache_data["$path"]="$size	$mtime	$md5"
    done < "$md5_cache"
fi

# Sets global md5_result. NOT called via $(...) — a command substitution would
# run this in a subshell, silently discarding its md5_cache_data[] updates
# (they'd vanish when the subshell exits, and the final cache rewrite would
# then overwrite the on-disk cache with that stale, incomplete state).
get_md5() {
    local path="$1"
    local size mtime cached cached_size rest cached_mtime cached_md5
    md5_result=""
    size="$(stat -c%s "$path" 2>/dev/null)" || return 1
    mtime="$(stat -c%Y "$path" 2>/dev/null)"

    cached="${md5_cache_data[$path]:-}"
    if [ -n "$cached" ]; then
        cached_size="${cached%%$'\t'*}"
        rest="${cached#*$'\t'}"
        cached_mtime="${rest%%$'\t'*}"
        cached_md5="${rest#*$'\t'}"
        if [ "$cached_size" = "$size" ] && [ "$cached_mtime" = "$mtime" ]; then
            md5_result="$cached_md5"
            return 0
        fi
    fi

    md5_result="$(md5sum "$path" | awk '{print $1}')"
    md5_cache_data["$path"]="$size	$mtime	$md5_result"
    # Append immediately so a killed/long run doesn't lose already-hashed work;
    # the cache is rewritten compactly at the end of a successful run.
    printf '%s\t%s\t%s\t%s\n' "$path" "$size" "$mtime" "$md5_result" >> "$md5_cache"
}

: > "$out_tsv"
printf 'study_id\tsubmitter_sample_id\tanalysis_name\tsubmitter_file_name\tfile_size\tfile_md5sum\tfile_type\tdata_type\n' >> "$out_tsv"

row_count=0
skipped_count=0

for fam_decodeur in "${decodeur_order[@]}"; do
    dest_dir="$dest_base/$fam_decodeur"
    [ -d "$dest_dir" ] || continue

    for raw_family in ${decodeur_members[$fam_decodeur]}; do
        version="${raw_family_version[$raw_family]:-}"
        tsv_file="$(tsv_for_version "$version")"

        if [ -z "$version" ] || [ -z "$tsv_file" ] || [ ! -f "$tsv_file" ]; then
            echo "WARNING: $raw_family (decodeur=$fam_decodeur) has unrecognized Version '$version' — skipped" >&2
            continue
        fi

        analysis_name="WGS-WDL_v$version"
        proband="$(find_proband "$raw_family" "$fam_decodeur")"
        load_templates "$tsv_file"

        for i in "${!tpl_names[@]}"; do
            template="${tpl_names[$i]}"
            scope="${tpl_scopes[$i]}"
            file_type="${tpl_types[$i]}"
            data_type="${tpl_data_types[$i]}"

            if [ "$scope" = "Family" ]; then
                expected_names=("${template/<family>/$raw_family}")
                sample_ids=("$proband")
            elif [ "$scope" = "Sample" ]; then
                expected_names=()
                sample_ids=()
                for sample in ${family_samples[$raw_family]:-}; do
                    expected_names+=("${template/<sample>/$sample}")
                    expected_names[-1]="${expected_names[-1]/<family>/$raw_family}"
                    sample_ids+=("$sample")
                done
            else
                continue
            fi

            for idx in "${!expected_names[@]}"; do
                expected_name="${expected_names[$idx]}"
                sample_id="${sample_ids[$idx]}"
                link_path="$dest_dir/$expected_name"

                if [ ! -e "$link_path" ]; then
                    echo "SKIPPED	$fam_decodeur	$raw_family	$expected_name	reason=no symlink at $link_path"
                    skipped_count=$((skipped_count + 1))
                    continue
                fi

                real_path="$(readlink -f "$link_path")"
                size="$(stat -c%s "$real_path" 2>/dev/null)"
                if [ -z "$size" ]; then
                    echo "SKIPPED	$fam_decodeur	$raw_family	$expected_name	reason=broken symlink at $link_path -> $real_path (target unreadable/missing)"
                    skipped_count=$((skipped_count + 1))
                    continue
                fi
                get_md5 "$real_path"
                md5="$md5_result"

                printf '%s\t%s\t%s\t%s/%s/%s\t%s\t%s\t%s\t%s\n' \
                    "$study_id" "$sample_id" "$analysis_name" \
                    "$s3_bucket" "$fam_decodeur" "$expected_name" \
                    "$size" "$md5" "$file_type" "$data_type" >> "$out_tsv"
                row_count=$((row_count + 1))
            done
        done
    done
done

# Rewrite the cache compactly from the final in-memory state.
{
    for path in "${!md5_cache_data[@]}"; do
        printf '%s\t%s\n' "$path" "${md5_cache_data[$path]}"
    done
} > "$md5_cache.tmp" && mv "$md5_cache.tmp" "$md5_cache"

echo "-----"
echo "Rows written: $row_count"
echo "Skipped (missing/broken symlink — see SKIPPED lines above): $skipped_count"
echo "Output: $out_tsv"
