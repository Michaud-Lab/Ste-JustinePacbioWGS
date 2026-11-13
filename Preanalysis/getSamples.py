import sys,os
import re
import json
import xml.etree.ElementTree as ET
import argparse
import logging
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
def select_xml(pb_formats):
	"""
	Pick the hifi_reads consensusreadset XML to use for a well.
	A re-run demultiplexing (lima) writes its XMLs under pb_formats/bc*/: when present, only those are considered.
	Then, by priority: re-demultiplexed + jasmine, jasmine, re-demultiplexed, the sequencer's original XML.
	Exits if no XML is found or if the highest priority level holds more than one XML.
	"""
	xml_matches = list(pb_formats.glob("bc*/*.hifi_reads.bc*.consensusreadset.xml"))
	if not xml_matches:
		xml_matches = list(pb_formats.glob("*.hifi_reads.bc*.consensusreadset.xml"))
	if not xml_matches:
		sys.exit(f"Expected to find hifi_reads xml files in {pb_formats} or {pb_formats}/bc*/, found none")
	print(f"Found these xml files:\n{[str(x) for x in xml_matches]}")

	priorities = [
		("re-demultiplexed jasmine", lambda n: ".re-demuxed." in n and ".jasmine." in n),
		("jasmine", lambda n: ".jasmine." in n),
		("re-demultiplexed", lambda n: ".re-demuxed." in n),
		("common", lambda n: re.fullmatch(r".*\.hifi_reads\.bc\d{4}\.consensusreadset\.xml", n) is not None),
	]
	for label, matches in priorities:
		candidates = [x for x in xml_matches if matches(x.name)]
		if len(candidates) == 1:
			print(f"Using {label} xml: {candidates[0]}")
			return candidates[0]
		if len(candidates) > 1:
			sys.exit(f"Unclear which {label} xml file to use:\n{[str(x) for x in candidates]}")
	sys.exit(f"None of the xml files in {pb_formats} match a known type:\n{[str(x) for x in xml_matches]}")


if __name__ == "__main__":

	parser = argparse.ArgumentParser(
		prog = 'getSample.py',
		usage = "python3 %(prog)s [-r run_id] [--config config_file (optional)]",	
		description='given a run_id, retrieve the samples included within. Prints them to run_ID_sample for future use')
	parser.add_argument('-r', '--run',help='Run id from Revio, should link to a directory with the same name contained in config args.Path.run_path',required=True) 
	parser.add_argument('-l', '--list', nargs='?', const='mySampleList.txt', default='mySampleList.txt')
	parser.add_argument('-c', '--config', nargs='?', const=None, default=None, help='Config file path (default env var WGS_CONFIG_FILE)')

	args		= parser.parse_args()
	if not args.config:
		args.config = os.environ.get('WGS_CONFIG_FILE')
	if not args.config:
		parser.error("No explicit config file given (-c) and default config var WGS_CONFIG_FILE is not set. You can set one with 'export WGS_CONFIG_FILE=<path to config file>'")
	configs	= Config.from_path(args.config)

	run_path	= configs.Paths.run_path
	run_folder	= Path(run_path + args.run)
	sample_sheet_path	= configs.Paths.sample_sheet_path

	#For our run, each sample is contained in a "well" folder (ex 1_A01, 1_B01...)
	directory_list		= [f for f in run_folder.resolve().glob('*') if not f.is_file()]
	sample_list	= []

	#For each well folder, we need to retrieve the sample name from the metadata file
	for well_folder in directory_list:
		well = well_folder.name
		
		xml_to_use = select_xml(Path(f"{well_folder}/pb_formats"))

		#The sample name is contained in this metadata file, in the pb_format folder		
		root = ET.parse(xml_to_use).getroot()
		raw_name = root.get("Name", "")
		reg = re.search(r"\(([^)]*)\)", raw_name)
		given_name = reg.group(1) if reg else ""

		print(f"Given name:{given_name}")
		#Special case for Decodeur and Care for rare (C4R) samples
		if given_name[0:3] == "HSJ" or given_name[0:3] == "C4R":
			family_name = given_name[:-3]
			if given_name[-2:] == "03" or given_name[-2:] == "04":
				role = "proband"
				gender = ""
				affected = True
			elif given_name[-2:] == "02":
				role = f"mother of {family_name}-03"
				gender = "Female"
				affected = False
			elif given_name[-2:] == "01":
				role = f"father of {family_name}-03"
				gender = "Male"
				affected = False
			else:
				print(f"Decodeur/C4R name didn't end with 01,02,03 or 04? Received:{given_name[-2:]}")
				sys.exit()

			if given_name[0:3] == "HSJ":
				study = "Decodeur"
			elif given_name[0:3] == "C4R":
				study = "C4R"
			status = {"Status":study, "Role":role, "Gender":gender, "Affected": affected}
			
		else:
			status = {}
			study = ""

		sample = Sample(args.run,well,given_name,status=status,study=study,config_file=args.config,xml_path=str(xml_to_use))
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
	existing_list = pd.read_csv(args.list,sep=";",
		names=["Name","Well","Barcode","run_id","Gender",
			"Status","Role","HPO","Study","XML","Affected"])
	existing_list = existing_list.where(existing_list.notnull(), "")
	for sample in sorted_list:
		skip_append=False
		if sample.name in existing_list["Name"].values:
			existing_sample=existing_list[existing_list['Name']==sample.name]
			if existing_sample.shape[0] > 1:
				print(f"More than one existing match for {sample.name}")
			for index, row in existing_sample.iterrows():
					existing_sample_object=Sample(
					run_id = str(row["run_id"]),
					well = str(row["Well"]),
					xml_path = str(row["XML"]),
					status = {"Status":str(row["Status"]),"Role":str(row["Role"]),
						"Gender":str(row["Gender"]),"Affected":row["Affected"]},
					HPOs = str(row["HPO"]).replace(";",","),
					study = row["Study"],
					config_file = args.config)
					if str(existing_sample_object) == str(sample):
						print(f"Sample {sample.name} is identical to pre-existing sample. Skipping append")
						skip_append=True
					else:
						print(f"Sample {sample.name} is similar to to pre-existing sample {row['Name']}:")
						print(sample)
						print("vs")
						print(existing_sample_object)
						print("Writing it to list anyways")
		if not skip_append:
			with open(args.list, "a") as fw:
				fw.write(f"{sample.__str__()};{sample.xml_path};{sample.case_status['Affected']}\n")
