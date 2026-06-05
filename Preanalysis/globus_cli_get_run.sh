#!/bin/bash
#SBATCH --job-name=Globus_get
#SBATCH --output=J-%x.%j.out
#SBATCH --account=def-rallard
#SBATCH --time=8:00:00

# Using the globus CLI, transfers the required runs then runs pre-analysis scripts.
# Required: A sample list file (TSV, CSV, or XLSX first sheet), usually produced by extractFamilies.py (option -s)
# You can request download of a family/trio (-f), an entire run (-r), or a single sample name (-n).
# After all Globus transfers complete:
#   - getSamples.py is run for each unique Run
#   - jointCallSampleSheet.py (family mode) or singletonSampleSheet.py (run/name mode) is run per case
set -eu

echo "Arguments:"
for var in "$@"; do
    echo "  $var"
done

usage() {
    echo "Usage: $0 -s <sample_list> [-f <trio_id>] [-r <run_name>] [-n <sample_name>] [-c <config_file>] [-t <tools_folder>]"
    echo ""
    echo "  -s  Path to sample list file [required] (.tsv, .csv, or .xlsx — first sheet only)"
    echo "  -f  Trio/family ID to transfer (matches 'Trio' column, e.g. p131)"
    echo "  -r  Run name to transfer (matches 'Run' column)"
    echo "  -n  Single sample name to transfer (matches 'PatientID' column)"
    echo "  -c  Config file path (default: ../.myconf.json relative to script)"
    echo "  -t  Tools folder path (default: ../Tools/ relative to script)"
    1>&2
    exit 1
}

# Defaults
config_file=".myconf.json"
tools_folder="Tools"
sample_list=""
family_id=""
run_id=""
name_id=""

while getopts "s:f:r:n:c:t:h" o; do
    case "${o}" in
        s)  sample_list=${OPTARG} ;;
        f)  family_id=${OPTARG};  echo "Will attempt to retrieve full family/trio: $family_id" ;;
        r)  run_id=${OPTARG};     echo "Will attempt to retrieve full run: $run_id" ;;
        n)  name_id=${OPTARG};    echo "Will attempt to retrieve single sample: $name_id" ;;
        c)  config_file=${OPTARG} ;;
        t)  tools_folder=${OPTARG} ;;
        h)  usage ;;
        :)  echo "Error: ${OPTARG} requires an argument."; exit 1 ;;
        *)  usage ;;
    esac
done

# --- Validate arguments ---

if [ -z "$sample_list" ]; then
    echo "Error: Sample list file (-s) is required. Supported formats: .tsv, .csv, .xlsx"
    usage
fi

if [ ! -f "$sample_list" ]; then
    echo "Error: Sample list file not found: $sample_list"
    exit 1
fi

if [ ! -f "$config_file" ]; then
    echo "Error: Config file not found: $config_file"
    exit 1
fi

n_modes=0
[ -n "$family_id" ] && n_modes=$((n_modes + 1))
[ -n "$run_id"    ] && n_modes=$((n_modes + 1))
[ -n "$name_id"   ] && n_modes=$((n_modes + 1))

if [ "$n_modes" -eq 0 ]; then
    echo "Error: You must specify one of -f <trio_id>, -r <run_name>, or -n <sample_name>."
    usage
fi

if [ "$n_modes" -gt 1 ]; then
    echo "Error: Only one of -f, -r, or -n may be specified at a time."
    usage
fi

# --- Set up virtual environment ---
function loadEnv() {
    local ENVDIR="$tools_folder/$1"
    local req_file="$2"
    if [ -d "$ENVDIR" ]; then
        source "$ENVDIR/bin/activate"
    else
        virtualenv --no-download "$ENVDIR"
        source "$ENVDIR/bin/activate"
        pip install --no-index --upgrade pip
        pip install -r "$req_file"
    fi
}

# --- Logging setup ---
# All output is tee'd to a timestamped log file so long-running sessions are preserved.
LOG_DIR="Logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/globus_send_$(date +%Y%m%d_%H%M%S)_${family_id}${run_id}${name_id}.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Logging to: $LOG_FILE"

# --- Read endpoints and paths from config ---
destination_endpoint="$(jq -r '.Transfers.working_endpoint'    "$config_file")"
destination_collection="$(jq -r '.Transfers.working_collection' "$config_file")"
destination_path="$(jq -r '.Paths.run_path'                    "$config_file")"
source_endpoint="$(jq -r '.Transfers.source_endpoint'          "$config_file")"
source_collection="$(jq -r '.Transfers.source_collection'      "$config_file")"
source_path="$(jq -r '.Transfers.source_run_path'              "$config_file")"

# --- Resolve cases to transfer using Python ---
# Produces two temp files:
#   $tmpfile_transfers  — one "Run/Cell" per line (for Globus)
#   $tmpfile_preanalysis — structured data for post-transfer steps (TSV: PatientID, Run, formatted_role)
tmpfile_transfers=$(mktemp /tmp/globus_transfers_XXXXXX.txt)
tmpfile_preanalysis=$(mktemp /tmp/globus_preanalysis_XXXXXX.tsv)
trap 'rm -f "$tmpfile_transfers" "$tmpfile_preanalysis"' EXIT

module load python/3.11
loadEnv "ENV_Preanalysis" "$tools_folder/requirementsPreanalysis.txt"

python3 - "$sample_list" "$family_id" "$run_id" "$name_id" \
          "$tmpfile_transfers" "$tmpfile_preanalysis" <<'EOF'
import sys
import os
import pandas as pd

tsv_path, family_id, run_id, name_id, out_transfers, out_preanalysis = sys.argv[1:]

# --- Load sample list: .tsv, .csv, or .xlsx (first sheet) ---
ext = os.path.splitext(tsv_path)[1].lower()

if ext in (".tsv", ".txt"):
    df = pd.read_csv(tsv_path, sep="\t", dtype=str, keep_default_na=False)
elif ext == ".csv":
    df = pd.read_csv(tsv_path, sep=",", dtype=str, keep_default_na=False)
elif ext in (".xlsx", ".xlsm"):
    import openpyxl, re
    df = pd.read_excel(tsv_path, sheet_name=0, dtype=str, engine="openpyxl",
                       keep_default_na=False)

else:
    print(f"Error: Unsupported file format '{ext}'. Use .tsv, .csv, or .xlsx", file=sys.stderr)
    sys.exit(1)

print(f"Loaded {len(df)} rows from {os.path.basename(tsv_path)} ({ext})", file=sys.stderr)

# Normalise column names
df.columns = df.columns.str.strip()

for col in ("PatientID", "Run", "Cell", "formatted_role", "Trio"):
    df[col] = df[col].fillna("").str.strip()    

# --- Filter rows ---
if family_id:
    matches = df[df["Trio"] == family_id.strip()]
    label = f"trio '{family_id}'"
elif run_id:
    matches = df[df["Run"] == run_id.strip()]
    label = f"run '{run_id}'"
elif name_id:
    matches = df[df["PatientID"] == name_id.strip()]
    label = f"sample '{name_id}'"
else:
    print("Error: no filter provided.", file=sys.stderr)
    sys.exit(1)

if matches.empty:
    print(f"Error: No entries found for {label} in {tsv_path}", file=sys.stderr)
    sys.exit(1)

print(f"Found {len(matches)} case(s) for {label}:", file=sys.stderr)
for _, row in matches.iterrows():
    print(f"  PatientID={row['PatientID']}  Run={row['Run']}  Cell={row['Cell']}  Role={row['formatted_role']}", file=sys.stderr)

# --- Write Run/Cell pairs for Globus transfers ---
with open(out_transfers, "w") as f:
    for _, row in matches.iterrows():
        f.write(f"{row['Run']}/{row['Cell']}\n")

# --- Write PatientID, Run, formatted_role for post-transfer steps ---
with open(out_preanalysis, "w") as f:
    for _, row in matches.iterrows():
        f.write(f"{row['PatientID']}\t{row['Run']}\t{row['formatted_role']}\n")
EOF

if [ ! -s "$tmpfile_transfers" ]; then
    echo "Error: No cases resolved. Exiting."
    exit 1
else
    echo "Cases to transfer:"
    cat "$tmpfile_transfers"
    echo "Preanalysis form:"
    cat $tmpfile_preanalysis
fi

# --- Transfer each case via Globus, collecting task IDs ---
echo ""
echo "=== PHASE 1: Globus transfers ==="
loadEnv "ENV_Globus" "$tools_folder/requirementsGlobus.txt"
globus login --gcs "${destination_endpoint}:${destination_collection}" \
             --gcs "${source_endpoint}:${source_collection}"

task_ids=()
while IFS= read -r run_cell; do
    source_folder="${source_path}/${run_cell}"
    destination_folder="${destination_path}/${run_cell}"
    transfer_label="${run_cell//\//-}"   # replace / with - for a valid label
    echo "  Submitting transfer: $source_folder --> $destination_folder"

    task_id=$(globus transfer \
        --label "${transfer_label}-transfer" \
        --recursive \
        --format unix \
        --jmespath 'task_id' \
        "${source_collection}:${source_folder}" \
        "${destination_collection}:${destination_folder}")

    echo "    Task ID: $task_id"
    task_ids+=("$task_id")
done < "$tmpfile_transfers"

# --- Wait for all transfers to complete ---
echo ""
echo "Waiting for ${#task_ids[@]} transfer task(s) to complete..."
all_ok=true
for task_id in "${task_ids[@]}"; do
    echo "  Waiting on task: $task_id"
    if ! globus task wait --timeout 28800 "$task_id"; then
        echo "  ERROR: Task $task_id did not complete successfully."
        globus task show "$task_id"
        all_ok=false
    else
        echo "  Task $task_id completed successfully."
    fi
done

if [ "$all_ok" = false ]; then
    echo "One or more Globus transfers failed. Aborting pre-analysis. Check log: $LOG_FILE"
    exit 1
fi

echo "All transfers complete."

# --- PHASE 2: Pre-analysis ---
echo ""
echo "=== PHASE 2: Pre-analysis ==="
loadEnv "ENV_Preanalysis" "$tools_folder/requirementsPreanalysis.txt"
SCRIPT_DIR="Preanalysis/"

# Step 1: getSamples.py — once per unique Run
echo "--- Step 1: getSamples.py per unique Run ---"
declare -A seen_runs
while IFS=$'\t' read -r patient_id run norm_role; do
    if [ -z "${seen_runs[$run]+_}" ]; then
        seen_runs[$run]=1
        echo "  Running getSamples.py for run: $run"
        python3 "$SCRIPT_DIR/getSamples.py" \
            -r "$run" \
            -c "$config_file"
    fi
done < "$tmpfile_preanalysis"

# Step 2: samplesheet generation — depends on mode
echo ""
echo "--- Step 2: Samplesheet generation ---"

if [ -n "$family_id" ]; then
    # Family mode: extract proband, mother, father from the preanalysis file
    proband_id=""
    mother_id=""
    father_id=""
    while IFS=$'\t' read -r patient_id run norm_role; do
        case "$norm_role" in
            proband) proband_id="$patient_id" ;;
            mother)  mother_id="$patient_id"  ;;
            father)  father_id="$patient_id"  ;;
        esac
    done < "$tmpfile_preanalysis"

    if [ -z "$proband_id" ]; then
        echo "Error: Could not identify a proband for family '$family_id'. Check the Role column."
        exit 1
    fi

    echo "  Family: $family_id  Proband: $proband_id  Mother: ${mother_id:-(none)}  Father: ${father_id:-(none)}"
    echo "  Running jointCallSampleSheet.py..."

    # Build optional mother/father args only if present
    optional_args=()
    [ -n "$mother_id" ] && optional_args+=(-m "$mother_id")
    [ -n "$father_id" ] && optional_args+=(-f "$father_id")

    python3 "$SCRIPT_DIR/jointCallSampleSheet.py" \
        -n "$family_id" \
        -p "$proband_id" \
        "${optional_args[@]}" \
        -c "$config_file"

else
    # Run or name mode: one singletonSampleSheet.py call per PatientID
    while IFS=$'\t' read -r patient_id run norm_role; do
        echo "  Running singletonSampleSheet.py for: $patient_id"
        python3 "$SCRIPT_DIR/singletonSampleSheet.py" \
            -p "$patient_id" \
            -c "$config_file"
    done < "$tmpfile_preanalysis"
fi

echo ""
echo "=== All done. Log saved to: $LOG_FILE ==="