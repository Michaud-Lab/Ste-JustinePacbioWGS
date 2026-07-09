import sys,os
import json
import subprocess
import argparse
from Sample import Sample
from pathlib import Path
from configurator import Config
import pandas as pd

"""
Retrieves samples info from Emedgene and Phenotips.
Give the run name (ie r84196_20250210_150130) as argument and a config file, optionally
the run folder must be present in the run_path specified in the config file (see ../.myconf.json for an example)
Will write the retrieved samples to a sample list that will be used to write the samplesheets
"""
if __name__ == "__main__":

	parser = argparse.ArgumentParser(
		prog = 'getSample.py',
		usage = "python3 %(prog)s [-r run_id] [--config config_file (optional)]",	
		description='given a run_id, retrieve the samples included within. Prints them to run_ID_sample for future use')
	parser.add_argument('-r', '--run',help='Run id from Revio, should link to a directory with the same name contained in config args.Path.run_path',required=True) 
	parser.add_argument('-l', '--list', nargs='?', const='mySampleList.txt', default='mySampleList.txt')
	parser.add_argument('-c', '--config', nargs='?', const='.myconf.json', default='.myconf.json')
	
	args		= parser.parse_args()
	configs  	= Config.from_path(args.config)

	run_path	= configs.Paths.run_path
	run_folder	= Path(run_path + args.run)
	sample_sheet_path	= configs.Paths.sample_sheet_path

	#For our run, each sample is contained in a "well" folder (ex 1_A01, 1_B01...)
	directory_list		= [f for f in run_folder.resolve().glob('*') if not f.is_file()]
	sample_list	= []

	#For each well folder, we need to retrieve the sample name from the metadata file
	for well_folder in directory_list:
		#The sample name is contained in this metadata file, in the pb_format folder
		grep_command = f"grep -o \"BioSample Name=\".*\"\" {well_folder}/pb_formats/*_s*.hifi_reads.bc*.consensusreadset.xml | cut -f2 -d'\"' | tr -d '\n'"
		grep_result = subprocess.run(grep_command, shell=True, capture_output=True, text=True)
		given_name = grep_result.stdout
		print(f"Well folder: {well_folder}")
		#Special case for Decodeur Samples
		if given_name[0:3] == "HSJ":
			family_name = given_name[:-3]
			if given_name[-2:] == "03" or given_name[-2:] == "04":
				role = "proband"
				gender = "null"
			elif given_name[-2:] == "02":
				role = f"mother of {family_name}-03"
				gender = "Female"
			elif given_name[-2:] == "01":
				role = f"father of {family_name}-03"
				gender = "Male"
			else:
				print(f"Decodeur name didn't end with 01,02,03 or 04? Received:{given_name[-2:]}")
				sys.exit()

			status = {"Status": "Decodeur", "Role":role, "Gender":gender, "Affected": False}
			print(f"Status for {given_name}: {status}")
		else:
			status = {}


		well = str(well_folder).split("/")[-1]
		sample = Sample(args.run,well,given_name,status=status,config_file=args.config)
		sample_list.append(sample)

	if not sample_list:
		print("Error: No samples found for the given run ID. Check directory path? In conf:")
		print(f"run_path: {run_path}")
		sys.exit(1)

	#Print the samples sorted by well (1_A01, 1_B01...)
	sorted_list = sorted(sample_list,key=lambda x: x.well.lower())
	for sample in sorted_list: 
		print(sample)

	#Check to see if the run_ID is already in the list
	#Having duplicates would cause problems later
	existing_list = pd.read_csv(args.list,sep=";",names=["Name","Well","Barcode","run_id","Gender","Status","Role","HPO","BAM","Affected","Study"])

	for sample in sorted_list:
		if sample.name in existing_list["Name"].values:
			print(f"mything:{existing_list[existing_list['Name']==sample.name]['run_id'].values}")
			if sample.run_id == existing_list[existing_list["Name"]==sample.name]["run_id"].values:
				print(f"Warning: Sample {sample.name} from run id {sample.run_id} already in list. Skipping append")
				sys.exit(0)
			else:
				print(f"Warning: Sample {sample.name} is already in list with run id {existing_list['run_id']} Appending anyways")

		with open(args.list, "a") as fw:
			fw.write(f"{sample.__str__()};{sample.bam_path};{sample.case_status['Affected']}\n")
