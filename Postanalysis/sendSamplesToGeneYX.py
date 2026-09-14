import os, sys, json
import argparse
from configurator import Config
from GeneYX import GeneYX
import logging

#from geneyx_analysis_api_CHUSJ.scripts.UnifyVcf.UnifyVcf import run
sys.path.append(sys.path[0]+'/geneyx.analysis.api_CHUSJ/scripts/UnifyVcf')
import PacBioUnifyVcf

#Small function to help search our output JSON
def find_keys_containing(my_dict, substring, name):
	keylist = [key for key in my_dict if substring in key]
	if len(keylist) == 0:
		logging.warning(f"Outputs not found in outputs.json for {name}")
		sys.exit()
	if "family" in keylist[0]:
		for file in my_dict[keylist[0]]:
			if name in file:
				return file
	elif "singleton" in keylist[0]:
		return my_dict[keylist[0]]
	else:
		logging.warning(f"Error in outputs.json for {name}: {keylist}")
		sys.exit()
	#return [file for file in my_dict[keylist[0]] if name in file]

#Send a group of samples to GeneYX, including sending analysis cases, qc data and assigning the appropriate group
if __name__ == "__main__":
	parser = argparse.ArgumentParser(
		prog = 'sendSamplesToGeneYX.py',
		usage = "python3 %(prog)s [-r list of the samplesheet containing the sample runs] [-g Optionally, group to assign (validation, prag, decode, controle)] [--config config_file (optional)]",	
		description='Send a group of samples to GeneYX including case analysis and QC data.')
	parser.add_argument('-r', '--run',help='Run id containing the list of sample name and path to the samplesheet, or direct link to the samplesheet',required=True) 
	parser.add_argument('-s', '--singleton',action='store_true',help='Use this option to specify the sample is a singleton. Use either this or -f')
	parser.add_argument('-f', '--family',action='store_true',help='Use this option to specify the sample is a family. Use either this or -s')
	parser.add_argument('-g', '--group',help='The group to which the samples should be assigned to', default='')
	parser.add_argument('-c', '--config', nargs='?', const=None, default=None, help='Config file path (default env var WGS_CONFIG_FILE)')
	args = parser.parse_args()
	if not args.config:
		args.config = os.environ.get('WGS_CONFIG_FILE')
	if not args.config:
		parser.error("No explicit config file given (-c) and default config var WGS_CONFIG_FILE is not set. You can set one with 'export WGS_CONFIG_FILE=<path to config file>'")

	configs  	= Config.from_path(args.config)
	sample_sheet_path	= configs.Paths.sample_sheet_path
	sample_list_name	= args.run
	sample_list = []

	if os.path.isfile(f"{args.run}"):
		sample_list_name = f"{args.run}"
	elif not os.path.isfile(sample_list_name):
		print(f"Filepath not found for {sample_list_name}")
		sys.exit(1)
	
	if args.family is False and args.singleton is False:
		print("Please specify is a singleton or a family by adding either -s or -f respectively")
		sys.exit(1)

	if args.family is True and args.singleton is True:
		print("Please specify only one of -f (family) OR -s (singleton)")
		sys.exit(1)

	with open(sample_list_name, 'r') as fr:
		#The sample sheet is different whether we deal with a family or singletons
		if args.family is True:
			"""
			family samplesheet format:
			pXXX,json_samplesheet_path
			proband:GMXXXXX,BAMpath
			mother:GMYYYYY,BAMpath
			father:GMZZZZZ,BAMpath
			"""
			header=next(fr).rstrip().split(',')
			sample_json = header[1]
			output_path = configs.Paths.output_path + '/' + header[0]

			if sample_json[0] != "p" and len(sample_json) != 9:
				print(f"The json file ({sample_json}) does not look like a family ID (pXXX). Are you sure this is not a singleton?")
				sys.exit(1)

			for line in fr:
				full_line = tuple(line.rstrip().split(','))
				
				role = full_line[0].split(':')[0]
				sample_name = full_line[0].split(':')[1]
				sample_list.append({"sample_name":sample_name,"role":role,"output":output_path})
				#We assume all samples will be sent to the same group
				if args.group == '':
					print("Please define a GeneYX group for the family (ie decode, prag)")
					sys.exit()
				else:
					group = args.group

		elif args.singleton is True:
			"""
			singleton samplesheet format:
			GMXXXXX,json_samplesheet_path,BAMpath,group (optional)
			GMYYYYY,json_samplesheet_path,BAMpath,group (optional)
			GMZZZZZ,json_samplesheet_path,BAMpath,group (optional)
			"""
			for line in fr:
				full_line=tuple(line.rstrip().split(','))
				
				#If group args is empty, we expect the groups to be defined in the list itself (individual assignment vs group assignment)
				sample_name = full_line[0]
				sample_json = full_line[1]
				if sample_json[0] == "p" and len(sample_json) == 9:
					print(f"The json file ({sample_json}) looks like a family ID (pXXX). Are you sure this is a singleton?")
					sys.exit(1)
				output_path = configs.Paths.output_path + '/' + sample_json.removesuffix('.json')
				sample_list.append({"sample_name":sample_name,"output":output_path})

				if args.group != '':
					print(f"Using given group name {args.group} for all samples")
					group = args.group
				elif len(full_line) == 3:
					logging.warning(f"No given group for sample {sample_name}")
					group = ''
				elif len(full_line) == 4:
					group = full_line[3]
				else:
					logging.warning(f"error: review number of fields in line {full_line}")
					sys.exit()


		else:
			print(f"Output file not found for in path: {output_path}")
			sys.exit()

		for sample in sample_list:
			output_path = sample["output"]
			sample_name = sample["sample_name"]
			#This file should contain the path to all outputs
			if os.path.exists(f"{output_path}/_LAST/outputs.json"):
				print("opening outputs file")
				with open(f"{output_path}/_LAST/outputs.json") as outputs_file:
					outputs_json = json.load(outputs_file)
				#The full key name depends on if the sample is part of a family or singleton
					small_variant_vcf = os.path.realpath(find_keys_containing(outputs_json,"phased_small_variant_vcf",sample_name))
					structure_variant_vcf = os.path.realpath(find_keys_containing(outputs_json,"phased_sv_vcf",sample_name))
					tandem_repeat_vcf = os.path.realpath(find_keys_containing(outputs_json,"phased_trgt_vcf",sample_name))
					cnv_vcf = os.path.realpath(find_keys_containing(outputs_json,"cnv_vcf",sample_name))
			
			
			GeneYX.unify_vcfs(sample_name,output_path,structure_variant_vcf,cnv_vcf,tandem_repeat_vcf)




	


			




