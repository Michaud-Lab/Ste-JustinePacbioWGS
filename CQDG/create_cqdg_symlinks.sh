#!/bin/bash

# For every clinical family (Famille_Decodeur) in Decodeur_list_updated.tsv,
# detect which humanwgs_family pipeline version produced each of its pipeline
# runs (Famille rows — a Quad's extra sibling is run separately under its own
# Famille, usually "<family_id>a") from OutputFamilies/$famille/_LAST/outputs.json,
# and pick the matching CQDG_files_v*.tsv template (file naming changed across
# pipeline versions). Look up each expected deliverable file inside
# OutputFamilies/$famille/_LAST/out/ and create a symlink to the real file
# (resolved through the miniwdl output_links symlinks) under
# dest_base/$famille_decodeur — all pipeline runs belonging to the same
# clinical family are merged into that one destination and report.
# Anything missing there, or whose output_links entry is dangling, is looked up
# by exact name under S3-Storage/$famille/ as a fallback (S3's haplotagged
# BAM/BAI never carry ".GRCh38" in their name, so that spelling is retried too).
# A per-family report and a global summary report are written to dest_base/reports.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
decodeur_list="$script_dir/Decodeur_list_updated.tsv"

source_base="/home/felixant/projects/ctb-rallard/COMMUN/PacBioData/OutputFamilies"
s3_base="/home/felixant/projects/ctb-rallard/COMMUN/PacBioData/S3-Storage"
dest_base="/home/felixant/projects/ctb-rallard/COMMUN/PacBioData/CQDG_Deliverables"
report_dir="$dest_base/reports"

mkdir -p "$dest_base" "$report_dir"

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Map a humanwgs_family workflow version to the CQDG file-naming template that
# matches it. Naming has changed across pipeline releases (e.g. hificnv was
# dropped, trgt/SV file names changed) so each version bucket has its own tsv.
tsv_for_version() {
    local version="${1#v}"
    case "$version" in
        2.*) echo "$script_dir/CQDG_files_v2.0.tsv" ;;
        3.0.*|3.1.*) echo "$script_dir/CQDG_files_v3.1-v3.0.tsv" ;;
        3.2.*) echo "$script_dir/CQDG_files_v3.2.tsv" ;;
        *) echo "" ;;
    esac
}

workflow_version_of() {
    grep -oE '"[A-Za-z_.]*workflow_version"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" 2>/dev/null \
        | tail -1 \
        | sed -E 's/.*"([^"]+)"$/\1/'
}

# Resolve a pipeline run (Famille) folder to its most recent run directory.
# Normally that's just OutputFamilies/$raw_family/_LAST — but a Quad sibling's
# separate run (e.g. "p077a") can lack a _LAST symlink entirely, so fall back
# to the lexicographically-last (i.e. most recent, since names are
# timestamp-prefixed) "*_humanwgs_family" directory. Echoes the resolved
# physical path, or nothing (exit 1) if the family has no output at all.
resolve_run_dir() {
    local raw_family="$1"
    local base="$source_base/$raw_family"
    [ -d "$base" ] || return 1
    if [ -e "$base/_LAST" ]; then
        readlink -f "$base/_LAST"
        return 0
    fi
    local candidate
    candidate="$(find "$base" -maxdepth 1 -type d -name '*_humanwgs_family' 2>/dev/null | sort | tail -1)"
    [ -n "$candidate" ] || return 1
    readlink -f "$candidate"
}

# --- Parse Decodeur_list_updated.tsv ---
# family_samples[raw_family]      -> unique sample IDs for that pipeline run
# decodeur_members[famille_decodeur] -> raw_family ids belonging to that clinical family
# decodeur_order[]                -> unique famille_decodeur values, first-seen order
declare -A family_samples
declare -A decodeur_members
declare -a decodeur_order

while IFS=$'\t' read -r raw_family famille_decodeur id _; do
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
done < <(tail -n +2 "$decodeur_list"; printf '\n')

# --- Load file templates (file_name, scope, output_name) from a given tsv ---
declare -a tpl_names
declare -a tpl_scopes
declare -a tpl_outnames

load_templates() {
    local tsv="$1"
    tpl_names=()
    tpl_scopes=()
    tpl_outnames=()
    while IFS=$'\t' read -r file_name file_type data_type scope description outname; do
        file_name="$(trim "$file_name")"
        scope="$(trim "$scope")"
        outname="$(trim "${outname:-}")"
        [ -z "$file_name" ] && continue
        tpl_names+=("$file_name")
        tpl_scopes+=("$scope")
        tpl_outnames+=("$outname")
    done < <(tail -n +2 "$tsv"; printf '\n')
}

# Resolve a set of found paths (from find) to unique real files, splitting out
# dangling symlinks. Fills globals real_paths[] and dangling_targets[].
resolve_matches() {
    local m rp
    declare -A seen=()
    real_paths=()
    dangling_targets=()
    for m in "$@"; do
        if [ -e "$m" ]; then
            rp="$(readlink -f "$m")"
            if [ -z "${seen[$rp]+x}" ]; then
                seen[$rp]=1
                real_paths+=("$rp")
            fi
        else
            dangling_targets+=("$(readlink -f -m "$m")")
        fi
    done
}

# List basenames found directly under a directory (one level of numbered
# sample subdirs included), for the MISSING/BROKEN diagnostics below.
# Optionally filtered to names containing $2 (a family/sample id hint).
list_basenames() {
    local dir="$1" hint="${2:-}"
    if [ ! -d "$dir" ]; then
        printf '(no such directory: %s)' "$dir"
        return
    fi
    local entries
    if [ -n "$hint" ]; then
        entries="$(find "$dir" -maxdepth 2 \( -type f -o -type l \) -iname "*$hint*" -printf '%f\n' 2>/dev/null | sort -u)"
    else
        entries="$(find "$dir" -maxdepth 2 \( -type f -o -type l \) -printf '%f\n' 2>/dev/null | sort -u)"
    fi
    if [ -z "$entries" ]; then
        printf '(nothing found in %s)' "$dir"
    else
        printf '%s: %s' "$dir" "$(echo "$entries" | paste -sd, -)"
    fi
}

summary_found=0
summary_missing=0
summary_ambiguous=0
summary_broken=0
summary_from_s3=0
: > "$report_dir/summary.report.txt"

for fam_decodeur in "${decodeur_order[@]}"; do
    family_report="$report_dir/$fam_decodeur.report.txt"
    : > "$family_report"

    dest_dir="$dest_base/$fam_decodeur"
    mkdir -p "$dest_dir"

    found=0
    missing=0
    ambiguous=0
    broken_count=0
    from_s3=0
    member_versions=()

    for raw_family in ${decodeur_members[$fam_decodeur]}; do
        if ! run_dir="$(resolve_run_dir "$raw_family")"; then
            echo "# raw_family=$raw_family: SOURCE MISSING (no run directory under $source_base/$raw_family)" >> "$family_report"
            echo "$fam_decodeur/$raw_family: SOURCE MISSING"
            continue
        fi

        version="$(workflow_version_of "$run_dir/outputs.json")"
        tsv_file="$(tsv_for_version "${version:-unknown}")"

        if [ -z "$version" ] || [ -z "$tsv_file" ] || [ ! -f "$tsv_file" ]; then
            echo "# raw_family=$raw_family: UNKNOWN WORKFLOW VERSION ($version) — no matching CQDG_files_v*.tsv, skipped" >> "$family_report"
            echo "$fam_decodeur/$raw_family: UNKNOWN WORKFLOW VERSION ($version)"
            continue
        fi

        load_templates "$tsv_file"
        member_versions+=("$raw_family:$version")

        echo "# raw_family=$raw_family (decodeur=$fam_decodeur) workflow_version=$version template=$(basename "$tsv_file")" >> "$family_report"

        out_dir="$run_dir/out"
        s3_dir="$s3_base/$raw_family"

        for i in "${!tpl_names[@]}"; do
            template="${tpl_names[$i]}"
            scope="${tpl_scopes[$i]}"
            outname="${tpl_outnames[$i]}"

            if [ "$scope" = "Family" ]; then
                expected_names=("${template/<family>/$raw_family}")
                expected_ids=("$raw_family")
            elif [ "$scope" = "Sample" ]; then
                expected_names=()
                expected_ids=()
                for sample in ${family_samples[$raw_family]:-}; do
                    expected_names+=("${template/<sample>/$sample}")
                    expected_names[-1]="${expected_names[-1]/<family>/$raw_family}"
                    expected_ids+=("$sample")
                done
            else
                continue
            fi

            search_root="$out_dir"
            if [ -n "$outname" ] && [ -d "$out_dir/$outname" ]; then
                search_root="$out_dir/$outname"
            fi

            for name_idx in "${!expected_names[@]}"; do
                expected_name="${expected_names[$name_idx]}"
                expected_id="${expected_ids[$name_idx]}"
                mapfile -t matches < <(find "$search_root" \( -type f -o -type l \) -name "$expected_name" 2>/dev/null)

                resolve_matches "${matches[@]}"

                if [ "${#real_paths[@]}" -eq 1 ]; then
                    ln -sfn "${real_paths[0]}" "$dest_dir/$expected_name"
                    echo "FOUND	$expected_name	${real_paths[0]}" >> "$family_report"
                    found=$((found + 1))
                    continue
                elif [ "${#real_paths[@]}" -gt 1 ]; then
                    echo "AMBIGUOUS	$expected_name	${real_paths[*]}" >> "$family_report"
                    ambiguous=$((ambiguous + 1))
                    continue
                fi
                had_dangling_in_outputfamilies="${#matches[@]}"
                of_dangling_targets=("${dangling_targets[@]}")

                # Nothing usable under out/ — the named output_links symlink
                # may itself be misnamed (e.g. a "pXXXWFailed" internal
                # alias), or the out/ farm may be incomplete for this run,
                # while the real work-dir file keeps the correct name.
                # Search the whole resolved run directory for an exact-name
                # physical file before giving up on OutputFamilies entirely.
                # _miniwdl_inputs holds per-task staged *copies* of upstream
                # inputs (not outputs), so a single logical file legitimately
                # shows up there under many call-* directories — exclude it
                # or every such file looks falsely ambiguous.
                mapfile -t workdir_matches < <(find "$run_dir" -type f -name "$expected_name" -not -path "*/_miniwdl_inputs/*" 2>/dev/null)
                resolve_matches "${workdir_matches[@]}"

                if [ "${#real_paths[@]}" -eq 1 ]; then
                    ln -sfn "${real_paths[0]}" "$dest_dir/$expected_name"
                    echo "FOUND_WORKDIR	$expected_name	${real_paths[0]}" >> "$family_report"
                    found=$((found + 1))
                    continue
                elif [ "${#real_paths[@]}" -gt 1 ]; then
                    echo "AMBIGUOUS	$expected_name	${real_paths[*]}" >> "$family_report"
                    ambiguous=$((ambiguous + 1))
                    continue
                fi

                # Still nothing — fall back to an exact-name lookup in
                # S3-Storage, which independently holds a subset of deliverables.
                mapfile -t s3_matches < <(find "$s3_dir" \( -type f -o -type l \) -name "$expected_name" 2>/dev/null)
                resolve_matches "${s3_matches[@]}"

                s3_found_category="FOUND_S3"
                if [ "${#real_paths[@]}" -eq 0 ] && [[ "$expected_name" == *.GRCh38.haplotagged.bam* ]]; then
                    # S3-Storage's haplotagged BAM/BAI never carry ".GRCh38"
                    # in their name — retry under that spelling, but still
                    # symlink it under the canonical name expected elsewhere.
                    alt_name="${expected_name/.GRCh38.haplotagged.bam/.haplotagged.bam}"
                    mapfile -t s3_matches < <(find "$s3_dir" \( -type f -o -type l \) -name "$alt_name" 2>/dev/null)
                    resolve_matches "${s3_matches[@]}"
                    s3_found_category="FOUND_S3_ALTNAME($alt_name)"
                fi

                if [ "${#real_paths[@]}" -eq 1 ]; then
                    ln -sfn "${real_paths[0]}" "$dest_dir/$expected_name"
                    echo "$s3_found_category	$expected_name	${real_paths[0]}" >> "$family_report"
                    found=$((found + 1))
                    from_s3=$((from_s3 + 1))
                elif [ "${#real_paths[@]}" -gt 1 ]; then
                    echo "AMBIGUOUS_S3	$expected_name	${real_paths[*]}" >> "$family_report"
                    ambiguous=$((ambiguous + 1))
                elif [ "$had_dangling_in_outputfamilies" -eq 0 ]; then
                    # Never found anywhere. Report where we looked and what
                    # was actually sitting there instead, so a mismatch
                    # (wrong name, wrong extension) is visible at a glance.
                    echo "MISSING	$expected_name	expected_under=$(list_basenames "$search_root")	expected_under_s3=$(list_basenames "$s3_dir" "$expected_id")" >> "$family_report"
                    missing=$((missing + 1))
                else
                    # out/ had a symlink for this file, but its target is
                    # gone. Report the dangling target(s) plus what's still
                    # in that target's parent directory (helps spot a
                    # rename/typo).
                    target_dir_listing=""
                    for dt in "${of_dangling_targets[@]}"; do
                        target_dir_listing+="${target_dir_listing:+; }$(list_basenames "$(dirname "$dt")")"
                    done
                    echo "BROKEN	$expected_name	expected_at=${of_dangling_targets[*]}	found_instead=$target_dir_listing	expected_under_s3=$(list_basenames "$s3_dir" "$expected_id")" >> "$family_report"
                    broken_count=$((broken_count + 1))
                fi
            done
        done
    done

    members_str="$(printf '%s;' "${member_versions[@]:-}")"
    echo "$fam_decodeur	OK	${members_str%;}	$found	$missing	$ambiguous	$broken_count	$from_s3" >> "$report_dir/summary.report.txt"
    summary_found=$((summary_found + found))
    summary_missing=$((summary_missing + missing))
    summary_ambiguous=$((summary_ambiguous + ambiguous))
    summary_broken=$((summary_broken + broken_count))
    summary_from_s3=$((summary_from_s3 + from_s3))

    echo "$fam_decodeur (${decodeur_members[$fam_decodeur]}): found=$found (of which from_s3=$from_s3) missing=$missing ambiguous=$ambiguous broken=$broken_count"
done

{
    echo "-----"
    echo "TOTAL	found=$summary_found	missing=$summary_missing	ambiguous=$summary_ambiguous	broken=$summary_broken	from_s3=$summary_from_s3"
} >> "$report_dir/summary.report.txt"

echo "-----"
echo "TOTAL: found=$summary_found (of which from_s3=$summary_from_s3) missing=$summary_missing ambiguous=$summary_ambiguous broken=$summary_broken"
echo "Symlinks in: $dest_base"
echo "Reports in: $report_dir"
