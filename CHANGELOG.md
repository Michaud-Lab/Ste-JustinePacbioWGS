# Changelog
 
All notable changes to this project will be documented in this file.
 
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
 
---
 
## [Unreleased]

## 2026-07-10: Refactor-Preanalysis_Study-Samples

### Changed

- Reviewed the logic and checks for `getSamples.py` as well as the internal methods for `Samples.py`.
- The Sample Class now has a "study" attribute and a "get_study_info" function that is mostly taken from the older script getStudy.py
- Having a duplicate sample name no longer prevents the `getSample.py` script from writing the entire run to the sample list. However, if every field in the sample list is identical to an existing sample, the sample in question will not be appended (the other samples of that run will)

## 2026-07-07: Refactor-MergeRequirements

### Changed
- Combined all "requirements" files together in a single `Tools/requirements.txt`
- Added miniwdl and miniwdl-slurm to `Tools/requirements.txt`, as well as the scipy-stack tools
- Added `Analysis/exec_script.sh`, meant to replace the one automatically installed from miniwdl-slurm (ENV/lib/python3.11/site-packages/miniwdl_slurm/scripts/exec_script.sh)
- added Hifi-WGS-WDL fork to Analysis folder

## 2026-07-03: Feature-ValidationSR_LR

### Added

- Added the `Postanalysis/run_concordance.sh` script. It is called from `Postanalysis/postprocessPart1.sh` for all samples of the family.
Its role is to fetch the short reads GVCF of the input sample and turn it into a VCF to call `Postanalysis/sr-lr_vcf_concordance.py`
- Added the `Postanalysis/sr-lr_vcf_concordance.py` python script. It takes two VCFs and outputs a concordance report and an interpretation of if both VCFs are likely from the same patient. 
- Added a log to most scripts called by `postprocessPart1.sh` to follow up on the progress of each run and FAILED/SUCCESS status.
For now I will try putting them in the same file as the "report_file" but it can be changed to "log_file" variable. 
- Added another log to keep track of which "cleanup_send" step was completed. This is a static log (without time). It allows
skipping previously completed transfers that can take a significant amount of time even for symlinks and prevent re-identification
- Added a check in `globus_cli_send.sh` to make sure all samples passed the `sr-lr_vcf_concordance.py` tests


## 2026-06-18: Refactor-MergeRequirements

### Added

- `Analysis/default_miniwdl.cfg` as an example config to use for miniwdl

### Changed

- `Preanalysis/extractFamilies.py`: replaced positional argument parsing with `argparse` to match the style of other scripts; added `-o/--output` flag for the output directory (replaces hardcoded `/mnt/user-data/outputs/`); core logic extracted into importable `extract_families()` and `load_inputs()` functions
- Consolidated `Tools/requirementsPreanalysis.txt`, `Tools/requirementsGlobus.txt`, `Tools/requirementsGeneYXUpload.txt`, and `Postanalysis/requirementsGeneYXUpload.txt` into a single `Tools/requirements.txt` (duplicates removed, highest version kept for conflicts)
- `postprocessPart1.sh`: removed `loadEnv` function for simplicity, all requirements are loaded immediately for any step. Now always installs from `Tools/requirements.txt`
- `globus_cli_get_run.sh` and `globus_cli_send.sh`: updated all requirements file references to `Tools/requirements.txt`
- README: completed Post-analysis and Quality Control Tools sections; updated Requirements section to reference the single consolidated file

### Removed

- `Tools/requirementsPreanalysis.txt`, `Tools/requirementsGlobus.txt`, `Tools/requirementsGeneYXUpload.txt`
- `Postanalysis/requirementsGeneYXUpload.txt` (duplicate of the Tools/ version)

### Fixed 

Fixed a bug in `Postanalysis/globus_cli_send.sh` not expecting "-m" option in getopts

---

## 2026-06-09

### Added

- `globus_cli_get_run.sh` script in Preanalysis: allows the selection of a family ID, or a single name or an entire run from the 'Feuil1' of the excel containing basic sample description. The script will download the selection from the newly added "source" collection and folder (usually Rorqual since it contains ou raw reads). It will download them in the "working" collection and path. Then, the script will automatically run the following steps `getSample.py` and `singletonSampleSheet.py` or `jointCallSampleSheet.py`. 

### Changed

- Added the "mode -m" argument to `globus_cli_send.sh`, used to tell if Triomix should be expected or not
- Changed the "origin_<...>" options in "Transfer" to "working_<...>". The wording is more appropriate given we now have a preanalysis transfer where the "origin" cluster is now the "working" cluster for the purpose of the Analysis step. 
- `getStudy.py`: Bugfix for duplicate samples and adds support for Decodeur names (start with "HSJ...")

### Removed

- Removed use of the "Phenotips" cluster in `Samples.py` and `Emedgene.py` 

---

## [1.0.0] - 2026-06-04

### Added

- License and changelog to the project. Tag v1.0.0

## 2026-06-04
 
### Added

- `extractFamilies.py` script in Preanalysis: reads the Bioinfo Excel list and infers new families, outputting `Familles_updated.tsv`
- Requirements file to accompany `extractFamilies.py`

### Changed

- Minor comment updates across scripts
---
 
## 2026-06-01
 
### Changed

- Postprocessing pipeline: integrated Copilot's review comments
- Added support for proband-father duos in the postprocessing pipeline
---
 
## 2026-03-04
 
### Changed

- Final changes to make postanalysis scripts fully functional
- Added tools and images for postanalysis
---
 
## 2026-01-09
 
### Changed

- Further integration changes for Rorqual HPC environment
---
 
## 2025-12-29
 
### Changed
- Separated the Globus send step into its own script, independent from the symlink script
- Refactored Globus transfers to use automatic flows
---
 
## 2025-12-17
 
### Fixed

- Hotfix for Globus requirements

### Changed

- Completed the cleanup-and-send file step
- Applied fixes to MultiQC integration
---
 
## 2025-12-11
 
### Added

- MultiQC integration and associated dependencies
---
 
## 2025-12-09
 
### Fixed

- Corrected config line

### Added

- Analysis folder with tmux launch script (PR #9)
---
 
## 2025-12-04
 
### Added

- First version of the bash post-processing pipeline (Part 1):
  - VCF normalization
  - GeneYX samplesheet generation and API submission
  - SVTopo for structural variant visualization
  - TrioMix for UPD and chimerism detection
  - PEDDY for familial relation and gender validation
  - Somalier for same-purpose validation
---
 
## 2025-10-27
 
### Added

- Analysis folder with tmux launch script for running the pipeline
- `miniwdl_cfg` config parameter (miniwdl installation instructions pending)
---
 
## 2025-10-23
 
### Added

- `getStudy.py` script: takes a line-separated list of sample identifiers and a Pragmatiq list CSV from SharePoint, and prints the cohort for each sample ID (PR #7)

### Fixed

- Bug fix for Decodeur sample handling in `getSamples.py`

### Changed

- Samplesheet updated for PacBio WGS v3.1: added fail BAM support for the tandem repeat calling step (PR #8)
---
 
## 2025-09-16
 
### Removed

- Removed pre-aligned BAMs from the repository (Rorqual refactor, PR #6)
---
 
## 2025-07-10
 
### Fixed

- Gender field now recognized case-insensitively (uppercase/mixed-case support)
- Removed stale samplesheet list file
---
 
## 2025-06-12
 
### Added

- Postprocessing Nextflow submodule added to the project (PR #4) (work in progress)

### Changed

- Cleaned up unused imports
---

## 2025-05-29
 
### Added

- Postanalysis structure and initial scripts (PR #3):
  - `GeneYX` object class (work in progress)
  - `sendSamplesToGeneYX.py` (partial): unifies SV, CNV, and TR VCFs for a given run list (work in progress)
- Updated README with finalized Preanalysis description

### Fixed

- `getSamples.py` updated to handle Decodeur samples not retrievable from Emedgene/Phenotips
- Adjusted header names in Preanalysis samplesheet scripts
---
 
## 2025-04-22
 
### Changed

- Refactored sample retrieval and samplesheet generation into separate steps (PR #2):
  - New `getSamples.py` writes samples to `mySampleList.csv`
  - `singletonSampleSheet` and `jointCallSampleSheet` now read from that list
  - All functions migrated to `argparse` for cleaner CLI usage
---
 
## 2025-03-31
 
### Added

- Initial commit of Postanalysis steps: list assignment and `sendSamples` script (work in progress)
---
 
## 2025-03-06
 
### Added

- Initial Preanalysis scripts (PR #1):
  - `Sample` and `Emedgene` classes
  - Samplesheet generation scripts for singleton and joint-call workflows
  - Example config file (`.myconf.json`)
---
 
## 2025-03-04
 
### Added

- Initial repository commit
