[← Back to main README](../README.md)

<img width="810" height="583" alt="image" src="https://github.com/user-attachments/assets/593bb9f8-68c5-42b2-b096-ab50f0808048" />


# Preanalysis

This directory contains the scripts used to prepare samples for the WGS Analysis pipeline. The pre-analysis phase covers two main tasks: (1) retrieving sample metadata from Emedgene and organising samples into families, and (2) downloading run files from the source cluster and generating the WDL-compatible samplesheets required by the Analysis pipeline.

Preanalysis is required both on Rorqual and Fir.
Usually, the following is used on Rorqual: "getSamples.py", "getStudy.py" and "extractFamilies.py".
These are the "metadata gathering scripts" that allow us to update the sample lists, such as the Bioinfo excel file. I usually manually copy the outputs of "getSamples.py" to the Bioinfo excel file, then I download the file from Sharepoint and upload it from local to Rorqual using:
```bash
scp Téléchargements/Bioinfo-LR_SampleData.xlsx felixant@rorqual.alliancecan.ca:/home/felixant/links/scratch/Ste-JustinePacbioWGS/
```

Then we can perform the extract_families.py on the updated excel sheet with:
```bash
python3 Preanalysis/extractFamilies.py -x Bioinfo-LR_SampleData.xlsx
```
This will give us a new list of potential families that are ready for analysis.
This brings us to FIR, where the actual analysis is performed.

The following scripts are used on Fir, typically:
"globus_cli_get_run.sh" with the family ID, sample ID or runID, which will download the corresponding run data from Rorqual using Globus, then will run automatically "getSample.py" then either "jointCallSampleSheet.py" or "singletonSampleSheet.py". 
Example:
```bash
sbatch Preanalysis/globus_cli_get_run.sh -s Bioinfo-LR_SampleData.xlsx -f p155
```
The getSamples.py and samplesheet scripts can also be called manually on Fir if the file transfer was done manually. 

> [!NOTE]
> For most scripts you can supply an alternate config file with `-c`. The default config name is `.myconf.json`. Most scripts also default to `mySampleList.txt` for the sample list path. See the [Config](../README.md#config) section of the main README for more details




---

- **getSamples.py**
  - *Usage*:
    ```bash
    python3 Preanalysis/getSamples.py -r <run_id> [-l sample_list] [-c config]
    ```
  - *Goal*: Retrieves sample metadata from Emedgene for all wells of a given run and appends them to the sample list. This is the precursor to all samplesheet-writing scripts — samples must appear in the list before a samplesheet can be generated for them.
  - *Outputs*: Prints sample information (name, gender, family status, HPO terms) to stdout and appends one row per sample to the sample list file (default: `mySampleList.txt`).

---

- **extractFamilies.py**
  - *Usage*:
    ```bash
    python3 Preanalysis/extractFamilies.py (-x bioinfo.xlsx | --feuil1 Feuil1.csv --familles Familles.csv) [-o output_dir]
    ```
  - *Goal*: Reads unclassified samples (`sing_trio_duo == "ToConfirm"`, no family assigned yet) from the Bioinfo Excel sheet and groups them into families based on role (proband / mother of / father of) and étude metadata. Assigns new family names (`p001`, `p002`, …) continuing from the highest existing number in the Familles sheet.
  - *Inputs*: Either the full Bioinfo Excel file via `-x` (extracts the **Feuil1** and **Familles** sheets automatically) or two pre-exported semicolon-separated CSVs via `--feuil1` / `--familles`.
  - *Outputs*: Three files written to the output directory (default: current directory):
    1. `Feuil1_updated.csv` — original Feuil1 with the `Trio` column filled in for newly assigned samples
    2. `Familles_updated.csv` — original Familles with new family rows appended
    3. `skipped_report.csv` — samples excluded due to missing étude, unrecognised role, or absent proband, with a reason column

---

- **getStudy.py (deprecated)**
  - *Usage*:
    ```bash
    python3 Preanalysis/getStudy.py -s <id_list> -p <pragmatiq_csv>
    ```
  - *Goal*: Cross-references a line-separated list of specimen IDs against a Pragmatiq CSV downloaded from SharePoint to extract study group (cohort) information. Useful for filling in étude columns in the Bioinfo Excel sheet.
  - *Outputs*: Writes a filtered table (specimen ID, proband ID, father ID, mother ID, comments, cohort) to stdout, followed by a cohort-only summary.

---

- **getHPOtermsFromList.py**
  - *Usage*:
    ```bash
    python3 Preanalysis/getHPOtermsFromList.py <sample_name_list>
    ```
  - *Goal*: Retrieves HPO terms from Phenotips for each sample in a line-separated name list, using the Emedgene API as an intermediary to resolve the Phenotips patient ID.
  - *Outputs*: Prints progress to stdout and writes one HPO term string per sample (semicolon-separated) to `returnHPO.txt`.

---

- **singletonSampleSheet.py**
  - *Usage*:
    ```bash
    python3 Preanalysis/singletonSampleSheet.py -p <proband_name> [-l sample_list] [-c config]
    ```
  - *Goal*: Generates a WDL-compatible JSON samplesheet for a single sample. Reads the sample's metadata from the sample list. This script must be run before launching the Analysis pipeline on a singleton.
  - *Outputs*: Two files written to `sample_sheet_path` from the config:
    1. `{run_id}_{well}_{sample_name}.json` — WDL pipeline samplesheet
    2. `{run_id}_samples` — text file listing all samples from this run for which a singleton samplesheet has been generated (used to batch-launch the pipeline)

---

- **jointCallSampleSheet.py**
  - *Usage*:
    ```bash
    python3 Preanalysis/jointCallSampleSheet.py -p <proband_name> -n <family_name> [-f <father_name>] [-m <mother_name>] [-l sample_list] [-c config]
    ```
  - *Goal*: Generates the joint-call WDL samplesheet for a family (duo or trio). Reads metadata for each member from the sample list. This script must be run before launching the Analysis pipeline on a family.
  - *Outputs*: Two files written to `sample_sheet_path` from the config:
    1. `{family_name}.json` — WDL joint-call samplesheet
    2. `{run_id}_samples` — batch list of samples from this run

---

- **globus_cli_get_run.sh**
  - *Usage*:
    ```bash
    sbatch Preanalysis/globus_cli_get_run.sh -s <sample_list> [-f <trio_id>] [-r <run_name>] [-n <sample_name>] [-c config] [-t tools_folder]
    ```
  - *Goal*: Downloads one or more runs from the source cluster (Rorqual) to the working cluster (Fir) via Globus, then automatically calls `getSamples.py` and the appropriate samplesheet script (`jointCallSampleSheet.py` for families, `singletonSampleSheet.py` for individuals). Reads cluster endpoints and paths from the `Transfers` section of the config. Exactly one of `-f`, `-r`, or `-n` must be specified.
  - *Arguments*:
    - `-s` — Sample list file **[required]** (`.tsv`, `.csv`, or `.xlsx` first sheet)
    - `-f` — Trio/family ID to transfer (matches the `Trio` column)
    - `-r` — Run name to transfer (matches the `Run` column)
    - `-n` — Single sample name to transfer (matches the `PatientID` column)
    - `-c` — Config file (default: `../.myconf.json` relative to the script)
    - `-t` — Tools folder (default: `../Tools/` relative to the script)
  - *Outputs*: Downloaded run files on the working cluster; updated sample list; generated samplesheet(s) written to `sample_sheet_path`.

---

## Helper modules

These files are imported by the scripts above and are not meant to be called directly.

| Module | Purpose |
|--------|---------|
| `Preanalysis/Sample.py` | Data class representing a single sequenced sample, including BAM path, metadata and samplesheet-writing methods. |
| `Preanalysis/Family.py` | Data class representing a family grouping, wrapping multiple Sample objects and providing joint-call samplesheet-writing logic. |
| `Preanalysis/Emedgene.py` | API client for the Emedgene platform: resolves sample names to EMG IDs and retrieves Phenotips patient IDs and HPO terms. |
| `Preanalysis/Qlin.py` | API client for the Qlin LIMS platform: authenticates and returns a bearer token. Requires a `Qlin` section in the config (`email`, `password`, `url`). **Not yet implemented: Qlin API is only usable with a VPN, not from the Alliance clusters.** |
