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
  - *Goal*: Main orchestrator for post-processing. Optionally runs `Analysis/seff_report.py` on the miniwdl run directory, normalizes per-sample VCFs, runs the GeneYX unified VCF step, uploads samples and the case to GeneYX, then submits Slurm jobs for Somalier, Peddy, SVTopo, Triomix (trios only), MultiQC, and per-sample SR/LR concordance checks. Optionally runs cleanup and initiates the Globus transfer to Narval.
  - *Arguments*:
    - `-i` Family or sample ID (must match a samplesheet in `sample_sheet_path`)
    - `-g` Study group: `Pragmatiq`/`prag`/`p`, `Decodeur`/`decode`/`d`, or `Validation`/`valid`/`v`
    - `-s` Run all steps non-interactively (skip prompts)
    - `-c` Optional config file (default: `../.myconf.json` relative to script)
  - *Outputs*:
    - `R-{id}_YYYY-MM-DD_HH-MM-SS_postprocess_report.txt` — timestamped log of each command's stdout/stderr
    - `status_{id}_YYYY-MM-DD_HH-MM-SS.log` — timestamped step status log (SUBMITTED / SUCCESS / FAILED per step)
    - `send_status.log` — static per-step status file for the cleanup/transfer steps; supports re-run skipping
    - `resource_efficiency_report_{id}.log` — `seff` resource-efficiency report (see [Analysis README](../Analysis/README.md#seff_reportpy)); the step is skipped if this file already exists

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

- **fetch_concordance_gvcf.sh**
  - *Usage*: `bash Postanalysis/fetch_concordance_gvcf.sh -n <sample_name> -o <output_dir> [-c <config_file>] [-l <log_file>]`
  - *Goal*: Downloads a sample's Illumina short-read GVCF from the staging server via `rclone`, ahead of `run_concordance.sh`. Split out from `run_concordance.sh` and run directly on the login node (not via `sbatch`) because job nodes can be very slow/blocked for this transfer (or completely impossible on Narval/Rorqual); `postprocessPart1.sh` calls this synchronously for each sample before submitting the `sbatch` job.
  - *Arguments*:
    - `-n` Sample name — used to locate the GVCF on `staging_juno:/pragmatiq-staging-sd4h/data/<sample_name>/`
    - `-o` Output directory; the GVCF is written under `<output_dir>/Concordance/`
    - `-c` Config file (for the `Rclone.short_reads_depot` path)
    - `-l` Status log file
  - *Outputs*: `<output_dir>/Concordance/<sample>.dragen.hard-filtered.gvcf.gz` (and its `.tbi` if present remotely).
  - *Exit codes*: `0` already local or downloaded successfully; `1` download error; `2` GVCF not found on staging (concordance should be skipped for this sample).

---

- **run_concordance.sh**
  - *Usage*: `sbatch Postanalysis/run_concordance.sh -n <sample_name> -v <lr_snv_vcf> -o <output_dir> [-f <fasta>] [-t <tools_folder>] [-l <log_file>]`
  - *Goal*: Verifies that a PacBio long-read VCF and its matching Illumina short-read GVCF originate from the same patient by computing genotype concordance across shared SNV sites (expected ≥ 90 % for same-patient pairs). Also runs a secondary 44-SNP fingerprint check with `bcftools isec` for quick confirmation.
  - *Arguments*:
    - `-n` Sample name — used to locate the already-downloaded GVCF under `<output_dir>/Concordance/`
    - `-v` Normalized PacBio SNV VCF (`.vcf.gz`), produced by `postprocessPart1.sh`
    - `-o` Output directory; results are written under `<output_dir>/Concordance/`
    - `-f` Reference FASTA (default: `$SCRATCH/GATK_references/Homo_sapiens_assembly38.fasta`)
    - `-t` Tools folder (for the Python virtualenv)
    - `-l` Status log file
  - *Outputs* (written to `<output_dir>/Concordance/`):
    - `concordance_report_<sample>.txt` — full genotype concordance report from `sr-lr_vcf_concordance.py`
    - `Isec/<sample>_summary.txt` — 44-SNP position summary (number of non-ref variants found)
    - `Isec/<sample>_report.txt` — list of mismatched positions (empty if none)
  - *Notes*: Requires `fetch_concordance_gvcf.sh` to have already downloaded the GVCF into `<output_dir>/Concordance/` — exits with an error otherwise. Converts the GVCF to VCF with GATK `GenotypeGVCFs` before comparison. The 44-SNP BED file is expected at `$SCRATCH/SNPs44.bed`.

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

- **proband_allele_depth.py**
  - *Usage*: `python3 Postanalysis/proband_allele_depth.py -t <prefix>.parental_only.tsv -o <output_prefix> --run-dir <family_run_dir>` (or `-g <proband.g.vcf.gz> [--rnc-vcf <raw_joint.vcf.gz>]` instead of `--run-dir`)
  - *Goal*: For every "parental-only" variant reported by `filter_parents.py`, reports the proband's allele depth (ref-supporting vs. alt-supporting reads). When the proband is an explicit hom-ref call in the joint VCF, its AD is read directly from the `parental_only.tsv`. When the proband is a no-call (`./.`) in the joint VCF, the same position is looked up in the proband's own gVCF instead, since the joint VCF carries no read information for no-calls but the gVCF still does (either an actual variant record with AD, or a hom-ref reference block, in which case alt support is 0). For those no-call variants, also looks up the proband's **RNC (Reason for No Call)** in the raw GLnexus joint VCF, explaining *why* GLnexus didn't call the proband there (e.g. `II` = the proband's own gVCF simply never called anything at that site; `DD` = GLnexus's depth reconciliation across the variant's span came up short, often due to an adjacent/overlapping low-depth call — see `filter_parents.py`'s REASON column vs. this script's RNC output for a worked example).
  - *Arguments*:
    - `-t` / `--parental-tsv` — `parental_only.tsv` from `filter_parents.py`
    - `-o` / `--output-prefix` — output prefix
    - `--run-dir` — HiFi-human-WGS-WDL family run directory (the folder containing `_LAST`). Infers `--gvcf` (`_LAST/out/small_variant_gvcf/0/*.g.vcf.gz`) and `--rnc-vcf` (`_LAST/call-joint/call-glnexus/out/vcf/*.vcf.gz`) automatically — an explicit `--gvcf`/`--rnc-vcf` overrides the inferred path. **Note**: the RNC source is the raw `call-joint/call-glnexus` task output, *not* the WDL's published `_LAST/out/joint_small_variants_vcf/` — that one has already had DP/AD/GQ/PL/RNC blanked out for no-calls by the time phasing is done with it.
    - `-g` / `--gvcf` — proband's single-sample gVCF (must be bgzip-compressed and tabix-indexed, `.tbi` alongside). Not needed if `--run-dir` is given.
    - `--rnc-vcf` — the raw, pre-phasing GLnexus joint VCF (see note above). Optional; if neither this nor `--run-dir` is given, the RNC lookup/report is skipped.
    - `--parental-vcf` — `parental_only.vcf.gz` from `filter_parents.py`, used to write the high-alt-support VCF subset below. Default: `--parental-tsv` with `.tsv` replaced by `.vcf.gz` (i.e. the matching file `filter_parents.py` wrote alongside the TSV).
    - `--min-alt-fraction` — alt allele fraction threshold for flagging a variant as possibly missed in the proband (default: 0.1)
    - `--min-depth` — total depth threshold for the same flag (default: 5)
  - *Outputs*:
    - `<prefix>.proband_depth.tsv` — per-variant CHROM/POS/REF/ALT, `GROUP` (`PROBAND_MISSING`/`PROBAND_REF`, from the TSV's REASON column), source of the depth call, proband/mother/father GT, ref/alt/other read depth, alt allele fraction, and `PROBAND_RNC` (`NA` for `PROBAND_REF` rows, or when no RNC source was given).
    - `<prefix>.proband_depth_bins.tsv` — for each group, the variant count, proportion, and mean total depth in each 0.05-wide alt-allele-fraction bin.
    - `<prefix>.proband_depth.png` — one column per group (`PROBAND_MISSING`, `PROBAND_REF`): a stacked proportion histogram of the proband's alt allele fraction (stacked by depth source for the missing group) on top, and the mean total depth per bin below. Useful for spotting parental-only calls where the proband actually shows partial read support for the variant, and for gauging whether the low-support bins are just low-depth noise.
    - `<prefix>.high_alt_support.vcf.gz` — the subset of parental-only variants where the proband's alt allele fraction and depth both clear the `--min-alt-fraction`/`--min-depth` thresholds (default: fraction > 0.1, depth > 5), for candidates the caller may have missed in the proband. `PROBAND_REF` records are copied straight from `parental_only.vcf.gz` (already informative — the proband's AD is right there). `PROBAND_MISSING` records are rewritten to a simplified `GT:DP:AD` FORMAT with the proband's field populated from the gVCF-derived depth instead of the joint VCF's uninformative `./.`; mother/father fields are carried over unchanged, and `PROBAND_SOURCE` is added to INFO.
    - `<prefix>.high_alt_support_genotype.tsv` — for the same high-alt-support variants, a full `MOTHER_CLASS`/`FATHER_CLASS`/`PROBAND_CLASS` cross-tab (each `HOM_REF`/`HET`/`HOM_ALT`/`MISSING`/`PARTIAL_MISSING`), from which counts like "homozygous-ALT parent but ref/missing proband call" (the strongest Mendelian-inheritance signal that the caller may have missed something) can be derived.
    - `<prefix>.high_alt_support_rnc.tsv` — proband RNC code counts among the flagged `PROBAND_MISSING` variants (only written when `--run-dir`/`--rnc-vcf` is given).
    - Per-group counts, the full per-bin table (count, proportion, mean depth), the high-alt-support variant count, a human-readable digest of the genotype cross-tab (proband GT class distribution; ≥1-parent-HOM_ALT and both-parents-HOM_ALT breakdowns; mean depth/alt-fraction per proband GT class), and the RNC code breakdown (with GLnexus's own header description of each code) are also printed to stdout.
  - *Notes*: Requires `pysam` and `matplotlib` (available via the `Tools/ENV` virtualenv).

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
