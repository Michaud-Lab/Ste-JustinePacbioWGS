import sys,os
from pathlib import Path
import subprocess
import logging
import glob
import json
from Sample import Sample
from configurator import Config

class Family:
	"""
	Family object composed of more than one Sample. 
	Each family needs a proband and at least one parent. 
	Should be able to accomodate quatuors (parents + sibling)
	TODO: Siblings support for samplesheets
	"""
	def __init__(self, family_ID, sample_group, config_file=os.path.expanduser(".myconf.json")):
		self.family_ID 	= family_ID

		self.proband	= sample_group["proband"]
		configs         = 	Config.from_path(config_file)
		self.tertiary_path = configs.Paths.tertiary_maps 
		self.parents	= {}
		if "mother" not in sample_group.keys() and "father" not in sample_group.keys():
			logging.warning(f"At least one parent should be given for Family {family_ID}")
			sys.exit()
		elif "mother" in sample_group.keys() and "father" not in sample_group.keys():
			self.parents.update({"mother":sample_group["mother"]})
		elif "mother" not in sample_group.keys() and "father" in sample_group.keys():
			self.parents.update({"father":sample_group["father"]})
		elif "mother" in sample_group.keys() and "father" in sample_group.keys():
			self.parents.update({"mother":sample_group["mother"]})
			self.parents.update({"father":sample_group["father"]})


	def write_joint_samplesheet(self):
		"""
		Writes a json samplesheet in given directory
		This samplesheet will be used by the Pacbi WGS WDL
		the naming convention is: {run_id}_{well}_{sample_name}.json
		"""

		proband_sample_dict = define_samplesheet_sample(self.proband)
		family_samples = [proband_sample_dict]
		for parent in self.parents:
			print(parent)
			item = self.parents[parent]
			role = item.case_status["Role"].split(" ")[0]
			print(proband_sample_dict)
			proband_sample_dict.update({f"{role}_id": item.name})
			family_samples.append(define_samplesheet_sample(item))


		sample_dict={"humanwgs_family.family":{
			"family_id": self.family_ID,
			"samples": family_samples
		},
		"humanwgs_family.phenotypes": self.proband.phenotypes,
		"humanwgs_family.ref_map_file": self.proband.refmaps_path,
		"humanwgs_family.tertiary_map_file": self.tertiary_path,
		"humanwgs_family.backend": "HPC"
		}
		
		sample_file= f"{self.proband.samplesheet_directory}/{self.family_ID}.json"
		print(f"Writing samplesheet to {sample_file}")
		print(sample_dict)
		with open(sample_file, 'w') as fw:
			json.dump(sample_dict, fw, indent=4)

	def __str__(self):
		return (f"Proband:{self.proband.name}\nParents:{self.parents}")


def define_samplesheet_sample(sample):
	"""
	Made as a small subfunction of write_joint_samplesheet, 
	Given a Sample object as input, will define the dictionary
	in the format expected by the WGS pipeline samplesheet

	Return: Dictionary
	"""
	role = sample.case_status["Role"].split(" ")[0]
	output_sample= {
		"sample_id"	: sample.name,
		"sex"		: sample.case_status["Gender"].upper(),
		"hifi_reads": [str(sample.bam_path)],
		"fail_reads": [str(sample.fail_bam)],
		"affected": str(sample.case_status["Affected"])
	}
	return output_sample
