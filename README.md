# Ste-JustinePacbioWGS

PacBio long-read Whole Genome Sequencing data processing, including [Pre-analysis](Preanalysis/README.md), WGS [Analysis](Analysis/README.md), and [Post-analysis](Postanalysis/README.md).

We describe here a workflow for analyzing and processing data received from the Revio PacBio sequencer acquired by the CHU Sainte-Justine. All scripts are designed to run on the Digital Research Alliance of Canada clusters (Narval, Rorqual, Fir).

## Data processing overview

<img width="1245" height="705" alt="image" src="https://github.com/user-attachments/assets/e573d5d5-eaaa-42f7-9b5d-ed84d0c9ab9c" />


Once out of the sequencer, the long-read sequencing data is automatically transferred to an in-house SMRTLink server for temporary storage. Since storage and computing resources are limited on this server, we transfer the data to a cluster of the Alliance, [Rorqual](https://docs.alliancecan.ca/wiki/Rorqual).

<img width="809" height="1055" alt="General_Steps_Flowchart" src="https://github.com/user-attachments/assets/5c2e1cac-0c28-4f80-8731-165f79da92dd" />

From there, we pre-process the data with the scripts in [Preanalysis/](Preanalysis/README.md). The analysis itself is done using PacBio's [WGS pipeline](https://github.com/PacificBiosciences/HiFi-human-WGS-WDL) — our fork lives in [Analysis/HiFi-human-WGS-WDL/](https://github.com/FelixAntoineLeSieur/HiFi-human-WGS-WDL) and contains minor changes to make the pipeline usable on Alliance clusters. It is performed on [Fir](https://docs.alliancecan.ca/wiki/Fir) rather than Rorqual because it is much faster. Once analysis is complete, post-processing steps (QC, tertiary upload, transfer) are described in [Postanalysis/](Postanalysis/README.md).

## Documentation

| Section | Description |
|---------|-------------|
| [Pre-analysis](Preanalysis/README.md) | Retrieve sample metadata, generate samplesheets, download runs from Rorqual |
| [Analysis](Analysis/README.md) | Run the WGS pipeline with miniwdl |
| [Post-analysis](Postanalysis/README.md) | Upload to GeneYX, QC reports, concordance checks, cleanup and transfer to Narval |

---

## Running the scripts

All Python dependencies are consolidated in `Tools/requirements.txt`. Versions are pinned for the Alliance clusters (`+computecanada` suffix).
To download the repo and its submodules:
```bash
git clone --recurse-submodules https://github.com/Michaud-Lab/Ste-JustinePacbioWGS.git
```
To set up the environment on an Alliance cluster:

```bash
module load python/3.11 scipy-stack/2026a
virtualenv --no-download Tools/ENV
source Tools/ENV/bin/activate
pip install --no-index --upgrade pip
pip install -r Tools/requirements.txt
cp Analysis/exec_script.sh Tools/ENV/lib/python3.11/site-packages/miniwdl_slurm/scripts/exec_script.sh
```

The last step replaces the native miniwdl-slurm exec script with one that uses `$SLURM_TMPDIR`, improving execution time and I/O efficiency on Alliance clusters.

Most bash scripts (`globus_get_run.sh`, `postprocessPart1.sh`, etc.) will install `Tools/ENV` automatically on first run if it does not exist.

---

## Config

The config file follows this format. See `configTemplate.json` for a template. The default location is `.myconf.json` at the root of the repo. Use `-c` to supply an alternate path for any script.

```json
{
	"Emedgene":
		{
			"username":"XXX",
			"password":"YYY",
			"endpoint":"https://chusaintejustine.emedgene.com"
		},
	"GeneYX":
		{
			"server": "https://analysis.geneyx.com",
			"apiUserId": "XXX",
			"apiUserKey": "YYY"
		},
	"Phenotips":
		{
			"database_tsv": "/home/felixant/links/scratch/phenotips_database.tsv"
		},
	"Paths":
		{
			"run_path": "/home/felixant/projects/ctb-rallard/COMMUN/PacBioData/",
			"ref_maps": "/home/felixant/scratch/HiFi-human-WGS-WDL/GRCh38.ref_map.v2p0p0.tsv",
			"sample_sheet_path": "/home/felixant/scratch/SampleSheet/",
			"output_path": "/home/felixant/scratch/Outputs",
			"tertiary_maps": "/home/felixant/scratch/HiFi-human-WGS-WDL/GRCh38.tertiary_map.v2p0p0.tsv",
			"miniwdl_cfg": "/home/felixant/scratch/Ste-JustinePacbioWGS/Analysis",
			"s3_folder": "/home/felixant/scratch/S3-Storage",
			"bioinfo_excel": "/home/felixant/links/scratch/Ste-JustinePacbioWGS/Bioinfo-LR_SampleData.xlsx",
			"sharepoint_list": "/home/felixant/links/scratch/Ste-JustinePacbioWGS/ListePRAGMatIQ.csv"
		},
	"Transfers":
		{
			"source_cluster": "Rorqual",
			"source_run_path": "/home/felixant/links/projects/rrg-rallard/shared/PacBioDataRorqual/SequencerData",
			"source_endpoint": "Globus UUID",
			"source_collection": "Globus UUID",
			"working_cluster": "Fir",
			"working_endpoint": "Globus UUID",
			"working_collection": "Globus UUID",
			"identity_file": "/home/felixant/.ssh/FirInteractive",
			"destination_cluster": "Narval",
			"destination_path": "/home/felixant/projects/ctb-rallard/COMMUN/PacBioData/OutputFamilies/",
			"destination_endpoint": "Globus UUID",
			"destination_collection": "Globus UUID"
		}
}
```

### Path fields

| Field | Description |
|-------|-------------|
| `run_path` | Directory containing raw runs from the Revio sequencer, organized as `{run_id}/{plate}/{sample}/` |
| `ref_maps` | Path to the WGS pipeline reference map TSV (from the resource bundle at [Zenodo 14027047](https://zenodo.org/records/14027047)) |
| `tertiary_maps` | Path to the WGS pipeline tertiary map TSV |
| `sample_sheet_path` | Directory where samplesheets (`.json`) and batch files (`.txt`) are written |
| `output_path` | Directory where the WGS pipeline writes results, organized by family/sample ID |
| `miniwdl_cfg` | Path to the miniwdl config file |
| `s3_folder` | Local staging folder for files to be synced to S3 / Narval |
| `bioinfo_excel` | Path to the bioinfo excel sheet (taken from [here](https://msss365.sharepoint.com/:x:/r/teams/CHUSJ-Projet_PacBio_LongRead/Documents%20partages/Bioinfo-LR_SampleData.xlsx?d=w4b851b2bbb084f239930f8eb7988ba61&csf=1&web=1&e=acDBQt)). Used by Preanalysis scripts|
| `sharepoint_list` | Path to the Pragmatiq sharepoint. () Used to get the study attribute for Samples and getStudy.py |

> [!NOTE]
> For `bioinfo_excel` and `sharepoint_list`, it is impossible to download them directly from the alliance clusters (the API blocks access).
> Therefore, you need to download the files locally from the URLs, then upload them to the alliance, for example with a scp command (see [Pre-analysis](Preanalysis/README.md) for an example.)

### Transfers fields

The `Transfers` section is used by `Preanalysis/globus_cli_get_run.sh` and `Postanalysis/globus_cli_send.sh`. It describes the three clusters in the workflow:

- **Source** (Rorqual): where raw sequencer data lands first
- **Working** (Fir): where analysis and post-processing run
- **Destination** (Narval): long-term storage for processed outputs

`identity_file` is the private SSH key for the automation/robot node. When present, scripts can transfer files without interactive password entry. Instructions for setting up the robot node are [here](https://msss365-my.sharepoint.com/:p:/g/personal/nicolas_perrot_hsj_ssss_gouv_qc_ca/IQBk4eS7U82LS7RY-GDUzAotAb5FslgG8GfcCOw3VRsNF0s?e=3xbdHn).

---

## Sample list

The sample list is built automatically when `Preanalysis/getSamples.py` is run on a run ID. Data for all samples in that run are appended to the list (default: `mySampleList.txt`). The list stores sample metadata across multiple runs to avoid repeated API calls.

Format (no header, semicolon-separated):

```
{sample_name};{plate_name};{barcode};{runID};{Gender};{Singleton|Duo|Trio};{Proband|mother of {probandID}|father of {probandID}};{HPOList};{path_to_bam};{Affected? True|False}
GM1XXX;2_B01;2002;r84196_XXX;Male;Duo;proband;HP:0000XXX,HP:000YYY;/path/to/bam;True
GM2XXX;2_C01;2003;r84196_XXX;Female;Duo;mother of GM1XXX;;/path/to/bam;False
```

Samples from this list are usually also recorded in the [Bioinfo Excel sheet](https://msss365.sharepoint.com/:x:/r/teams/CHUSJ-Projet_PacBio_LongRead/Documents%20partages/Bioinfo-LR_SampleData.xlsx?d=w4b851b2bbb084f239930f8eb7988ba61&csf=1&web=1&e=IpObDK), which is the input for `Preanalysis/extractFamilies.py`.

> [!NOTE]
> For most scripts you can use `-c` to supply an alternate config file. Otherwise the default is `.myconf.json`. Some scripts also use a default sample list path (`mySampleList.txt`).
