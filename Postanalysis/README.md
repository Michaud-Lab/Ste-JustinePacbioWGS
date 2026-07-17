[← Back to main README](../README.md)

<img width="810" height="990" alt="image" src="https://github.com/user-attachments/assets/88774e97-4489-4452-864e-bd95a2cee55b" />


# Post-analysis

Once WGS pipeline outputs are available (i.e. the folder "out" can be found in the "_LAST" run folder of the analysis), the post-analysis phase uploads data to tertiary analysis platforms, generates QC reports, validates sample identity, and transfers results to long-term storage.

Most steps are interactively orchestrated by `postprocessPart1.sh`, which submits the QC tools as Slurm jobs and handles the GeneYX uploads. Using the '-s' option runs everything without interactivity. Several log files are genrated by this script. The ones specific to launched steps will be found in their respective folders, except the one from multiqc ("J-multiqc_<familyID>.<slurm_jobID>.out) and the final globus transfer ("J-final_globus_<familyID>.<slurm_jobID>.out"). There is also a generic log with the name "R-<familyID>_<date>_postprocess_report.txt" and a static "summary_report.txt" summarizing the state of different steps. Normally, the final globus transfer will not be performed if certain key steps were not completed successfully, namely the Peddy/Somalier step (including the absence of pedigree errors), the Triomix step (for trios only), the SVTOPO step, the MultiQC step and the concordance step. Finally,the cleanup and transfer steps at the end can be automatically skipped and resumed on re-run using the `send_status.log` file.

---

## Rclone transfers

### decodeur-pacbio

We make use of rclone to access cloud resources related to Postanalysis. 
The first cloud resources is the one where we store the haplotagged BAM (analysis output). Everyday at 3am URLs to this cloud are generated and sent to GeneYX. This first cloud is described in the **s3_bam_storage** in [config](../README.md#config). By default it is named decodeur-pacbio 

```
>rclone config
>n (new account)
>decodeur-pacbio (name)
>4 (S3 Storage)
>3 (Ceph Provider)
>Enter
>[access_key_id]
>[secret_access_key]
>Enter
>https://objets.juno.calculquebec.ca/ (endpoint)
>Enter x 5... (Leave blank until done)
```

You can test the rclone config with:
```
>rclone ls decodeur-pacbio:decodeur-pacbio/S3-Storage/test_monarch_01
```

The path to samples is "decodeur-pacbio/S3-Storage/["family_id"]/["proband"/"mother"/"father"]
It contains the haplotagged bams and the cpg_pileup files. 

---

The second cloud resource hosts short reads analysis results. We need it to compare variants obtained from long reads analysis to the short reads GVCFs. This second cloud is described in the **short_reads_depot** in [config](../README.md#config). By default it is named staging_juno

```
>rclone config
>n (new account)
>staging_juno (name)
>4 (S3 Storage)
>7 (Minio Provider)
>Enter
>[access_key_id]
>[secret_access_key]
>Enter
>https://objets.juno.calculquebec.ca (endpoint)
>Enter x 5... (Leave blank until done)
```
You can test the rclone config with:
```
rclone ls staging_juno:/pragmatiq-staging-sd4h/data/[sample_name]
```

	"Rclone":
		{
			"short_reads_depot":"staging_juno:/pragmatiq-staging-sd4h/data",
			"s3_bam_storage":"decodeur-pacbio:decodeur-pacbio/S3-Storage"
		}

## Scripts

- **postprocessPart1.sh**
  - *Usage*: `bash Postanalysis/postprocessPart1.sh -i <familyID> -g <group> [-s] [-c config]`
  - *Goal*: Main orchestrator for post-processing. Normalizes per-sample VCFs, runs the GeneYX unified VCF step, uploads samples and the case to GeneYX, then submits Slurm jobs for Somalier, Peddy, SVTopo, Triomix (trios only), MultiQC, and per-sample SR/LR concordance checks. Optionally runs cleanup and initiates the Globus transfer to Narval.
  - *Arguments*:
    - `-i` Family or sample ID (must match a samplesheet in `sample_sheet_path`)
    - `-g` Study group: `Pragmatiq`/`prag`/`p`, `Decodeur`/`decode`/`d`, or `Validation`/`valid`/`v`
    - `-s` Run all steps non-interactively (skip prompts)
    - `-c` Optional config file (default: `../.myconf.json` relative to script)
  - *Outputs*:
    - `R-{id}_YYYY-MM-DD_HH-MM-SS_postprocess_report.txt` — timestamped log of each command's stdout/stderr
    - `status_{id}_YYYY-MM-DD_HH-MM-SS.log` — timestamped step status log (SUBMITTED / SUCCESS / FAILED per step)
    - `send_status.log` — static per-step status file for the cleanup/transfer steps; supports re-run skipping

---

- **outputs_Json.sh**
  - *Usage*: `bash Postanalysis/outputs_Json.sh -i <familyID> -d <directory> [-c config]`
  - *Goal*: Parses the miniwdl `outputs.json` file to resolve absolute file paths and updates them to match the destination path on Narval. Creates symlinks in the local S3-Storage folder (one per file type per sample), then rsyncs that folder to Narval via the robot node.
  - *Arguments*: `-i` family ID, `-d` family output directory, `-c` optional config file.
  - *Outputs*:
    - `outputs.json` updated in-place with destination-corrected paths (original backed up as `outputs.json.bak2`)
    - Symlinks in `$s3_folder/<familyID>/<role>/` for haplotagged BAMs, BAM indices, and CpG pileup BED files
    - `fullsampleSheet.csv` — maps each sample role to its new destination path

---

- **globus_cli_send.sh**
  - *Usage*: `sbatch Postanalysis/globus_cli_send.sh -i <familyID> -d <directory> -m <duo|trio> [-t tools_folder] [-r] [-c config] [-l log_file] [-S send_status_log]`
  - *Goal*: Pre-flight check followed by a Globus transfer of the processed family directory from the working cluster (Fir) to Narval. The pre-flight check verifies that all required QC outputs exist (Peddy report, SVTopo HTML reports, Triomix PDF [trio only], MultiQC report, concordance reports). Fails fast with a `summary_report.txt` if any are missing.
  - *Arguments*:
    - `-i` Family ID
    - `-d` Family output directory to transfer
    - `-m` Mode: `duo` or `trio`
    - `-t` Tools folder (for the Python virtualenv)
    - `-r` Use robot node for symlink rsync (requires `identity_file` in config)
    - `-c` Config file
    - `-l` Status log file (receives FAILED line on job failure)
    - `-S` Send-status log file (receives `globus_send: SUCCESS` on completion)
  - *Outputs*: A Globus transfer to `destination_path/<familyID>/`; `summary_report.txt` in the family directory listing which checks passed or failed.

---

- **cleanup.sh**
  - *Usage*: `bash Postanalysis/cleanup.sh -i <familyID> -d <directory> [-c config]`
  - *Goal*: Removes large intermediate miniwdl work directories to free scratch space. Keeps all final outputs, QC reports, and VCFs. Safe to run after files have been transferred to Narval.
  - *What is removed*: pbmm2 alignment chunks, split BAM work directories, samtools merge work directories, merged HiFi read intermediates, captured fail-read intermediates, DeepVariant make-examples shards.
  - *Outputs*: Freed disk space on the working cluster.

---

- **send_Symlinks_Narval.sh**
  - *Usage*: `bash Postanalysis/send_Symlinks_Narval.sh -i <familyID> -d <directory> [-r] [-c config]`
  - *Goal*: Transfers the symlinks from the working directory to Narval using rsync (`-l` flag to preserve symlinks). Useful when Globus is unavailable or for re-sending symlinks after an update.
  - *Arguments*: `-i` family ID, `-d` directory, `-r` use robot/automation node (requires `identity_file` in config), `-c` config.
  - *Outputs*: Symlinks replicated under `destination_path/<familyID>/` on Narval.

---

- **run_concordance.sh**
  - *Usage*: `sbatch Postanalysis/run_concordance.sh -n <sample_name> -v <lr_snv_vcf> -o <output_dir> [-f <fasta>] [-t <tools_folder>] [-l <log_file>]`
  - *Goal*: Verifies that a PacBio long-read VCF and its matching Illumina short-read GVCF originate from the same patient by computing genotype concordance across shared SNV sites (expected ≥ 90 % for same-patient pairs). Also runs a secondary 44-SNP fingerprint check with `bcftools isec` for quick confirmation.
  - *Arguments*:
    - `-n` Sample name — used to locate the GVCF on `staging_juno:/pragmatiq-staging-sd4h/data/<sample_name>/`
    - `-v` Normalized PacBio SNV VCF (`.vcf.gz`), produced by `postprocessPart1.sh`
    - `-o` Output directory; results are written under `<output_dir>/Concordance/`
    - `-f` Reference FASTA (default: `$SCRATCH/GATK_references/Homo_sapiens_assembly38.fasta`)
    - `-t` Tools folder (for the Python virtualenv)
    - `-l` Status log file
  - *Outputs* (written to `<output_dir>/Concordance/`):
    - `concordance_report_<sample>.txt` — full genotype concordance report from `sr-lr_vcf_concordance.py`
    - `Isec/<sample>_summary.txt` — 44-SNP position summary (number of non-ref variants found)
    - `Isec/<sample>_report.txt` — list of mismatched positions (empty if none)
  - *Notes*: Downloads the GVCF via `rclone` (requires `staging_juno` remote configured). Converts the GVCF to VCF with GATK `GenotypeGVCFs` before comparison. Skips gracefully if the GVCF is not found on the staging server. The 44-SNP BED file is expected at `$SCRATCH/SNPs44.bed`.

---

- **sr-lr_vcf_concordance.py**
  - *Usage*: `python3 Postanalysis/sr-lr_vcf_concordance.py --vcf1 <lr.vcf.gz> --vcf2 <sr.vcf.gz> [--min-gq 20] [--min-dp 8] [--output report.txt]`
  - *Goal*: Compares two VCFs (PacBio/DeepVariant vs. Illumina/GATK) and produces a cross-platform SNV concordance report to confirm they come from the same patient.
  - *Arguments*:
    - `--vcf1` First VCF (typically long-read / DeepVariant)
    - `--vcf2` Second VCF (typically short-read / GATK)
    - `--min-gq` Minimum genotype quality filter (default: 20)
    - `--min-dp` Minimum read depth filter (default: 8)
    - `--output` Optional path to save the text report
  - *Outputs*: Formatted concordance report printed to stdout (ANSI coloured); optionally saved to file. The report includes variant counts, shared-site intersection size, Jaccard index, genotype confusion matrix, and a verdict:
    - **SAME PATIENT** (≥ 90 % genotype concordance on shared SNVs)
    - **AMBIGUOUS** (75–90 %)
    - **LIKELY DIFFERENT PATIENTS** (< 75 %)
  - *Notes*: Requires `cyvcf2` and `numpy` (available via the `Tools/ENV` virtualenv). Called automatically by `run_concordance.sh`; can also be run standalone for ad-hoc comparisons.

---

- **sendSamplesToGeneYX.py** *(legacy — currently handled by postprocessPart1.sh)*
  - *Usage*:
    - Family: `python3 Postanalysis/sendSamplesToGeneYX.py -r <family_run_list> -f [-g <group>] [-c config]`
    - Singleton: `python3 Postanalysis/sendSamplesToGeneYX.py -r <singleton_run_list> -s [-g <group>] [-c config]`
  - *Goal*: For each sample in the run list, locates the WGS pipeline output VCFs in `output_path/_LAST/outputs.json`, merges them into a single unified VCF using `PacBioUnifyVcf`, and sends the case to GeneYX. Optionally assigns samples to a study group.
  - *Inputs*: A run list file. **Family format** (header then one `role:sampleName,BAMpath` per member):
    ```
    pXXX,pXXX.json
    proband:GMXXXXX,/path/to/bam
    mother:GMYYYYY,/path/to/bam
    father:GMZZZZZ,/path/to/bam
    ```
    **Singleton format** (one `sampleName,samplesheet.json,BAMpath[,group]` per line):
    ```
    GMXXXXX,GMXXXXX.json,/path/to/bam,validation
    ```
  - *Outputs*: Unified VCF files at `output_path/{sample_name}-unifiedVCF.vcf.gz`; cases uploaded to GeneYX.

---

## Quality Control Tools

The `Tools/` directory contains Apptainer-based wrappers for QC tools. Each is launched as a Slurm job by `postprocessPart1.sh` but can also be run independently. Each tool has a `*call_from_image.sh` launcher and a corresponding `.def` Apptainer definition file. All accept `-l <log_file>` to write SUCCESS/FAILED status to a shared log.

- **Somalier** (`Tools/Somalier/somaliercall_from_image.sh`)
  - *Usage*: `sbatch Tools/Somalier/somaliercall_from_image.sh -i <familyID> -p <proband> -1 <parent1> [-2 <parent2>] -r <fasta> -d <directory> [-s sites_vcf] [-l log_file]`
  - *Goal*: Sample-level relatedness and ancestry inference. Runs `somalier extract` on per-sample VCFs, then `somalier relate` to verify family relationships, and `somalier ancestry` to compare against 1000 Genomes data.
  - *Outputs* (written to `<directory>/Somalier_analyses/`): relatedness HTML report, ancestry HTML report, extracted `.somalier` profiles.

- **Peddy** (`Tools/Peddy/peddycall_from_image.sh`)
  - *Usage*: `sbatch Tools/Peddy/peddycall_from_image.sh -i <familyID> -p <proband> -1 <parent1> [-2 <parent2>] -d <directory> [-l log_file]`
  - *Goal*: Sex inference and relatedness checking against population reference data. Cross-validates the declared pedigree structure against genotype data. Merges per-sample normalized VCFs before running.
  - *Outputs* (written to `<directory>/Peddy_analyses/`): `{familyID}_peddy.html` interactive report, `{familyID}_peddy.ped_check.csv` (used by `globus_cli_send.sh` to detect parent errors).

- **MultiQC** (`Tools/MultiQc/multiQccall_from_image.sh`)
  - *Usage*: `sbatch Tools/MultiQc/multiQccall_from_image.sh [-l log_file]` (run from the family output directory)
  - *Goal*: Aggregates per-sample QC metrics from pipeline outputs into a single interactive HTML report.
  - *Outputs*: `multiqc_report.html` in the current directory.

- **SVTopo** (`Tools/SVTopo/svtopocall_from_image.sh`)
  - *Usage*: `sbatch Tools/SVTopo/svtopocall_from_image.sh -p <prefix> -b <haplotagged_bam> -i <bam_index> -s <supporting_reads_json> -v <sv_vcf> -r <resource_folder> -o <output_dir> -t <tools_folder> [-l log_file]`
  - *Goal*: Structural variant topology visualization. Produces interactive diagrams of complex SVs from the PacBio SV VCF, using a repeat-masker BED for annotation.
  - *Outputs* (written to `<output_dir>/SVTOPO_OUTPUTS/<prefix>_svtopo/`): `index.html` interactive report and per-SV diagram files.

- **Triomix** (`Tools/Triomix/triomixcall_from_image.sh`)
  - *Usage*: `sbatch Tools/Triomix/triomixcall_from_image.sh -p <proband_bam> -m <mother_bam> -f <father_bam> -r <fasta> -o <output_dir> [-l log_file]`
  - *Goal*: Detects sample contamination or mix-up in trio data by testing for unexpected allele sharing between family members. Trios only (not applicable to duos).
  - *Outputs* (written to `<output_dir>/Triomix_analyses/`): `*.child.counts.plot.pdf` — per-chromosome allele-sharing plot.

---

## Utility modules

These files are imported by the scripts above and are not meant to be called directly.

| Module | Purpose |
|--------|---------|
| `Postanalysis/GeneYX.py` | API client for GeneYX: authentication, VCF unification (`unify_vcfs`), group assignment (`group_assign`). Imported by `sendSamplesToGeneYX.py` and `assignListToGeneYXGroup.py`. |
| `Postanalysis/getSampleListFromGeneYX.py` | Retrieves the full sample list from GeneYX and writes it to `allGeneYXSampleList.json`. Uses a hardcoded config path; intended for one-off administrative queries. |
| `Postanalysis/filter_parents.py` | Single-pass filter for joint-called trio VCFs (GLNexus / DeepVariant). |
| `Postanalysis/assignListToGeneYXGroup.py` | Assigns a list of samples to a GeneYX study group. Cross-references the provided name list against a CSV export of GeneYX's full VCF list. |
