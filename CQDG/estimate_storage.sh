#!/bin/bash

# Takes a tsv list of Decodeur families. For each unique family_ID in the
# "Famille" column, report the disk size of $s3_folder/$family_ID, then
# report the total disk size used by all family folders.

set -euo pipefail

s3_folder="$HOME/projects/ctb-rallard/COMMUN/PacBioData/S3-Storage"
decodeur_list="$(dirname "$0")/Decodeur_list.tsv"

total_kb=0

for family_id in $(awk -F'\t' 'NR>1 && $1!="" {print $1}' "$decodeur_list" | sort -u); do
    family_path="$s3_folder/$family_id"

    if [ ! -d "$family_path" ]; then
        echo "$family_id: MISSING ($family_path not found)"
        continue
    fi

    size_kb=$(du -skL "$family_path" | cut -f1)
    total_kb=$((total_kb + size_kb))

    size_human=$(du -shL "$family_path" | cut -f1)
    echo "$family_id: $size_human"
done

total_human=$(numfmt --to=iec --from-unit=1024 "$total_kb")
echo "-----"
echo "Total: $total_human"
