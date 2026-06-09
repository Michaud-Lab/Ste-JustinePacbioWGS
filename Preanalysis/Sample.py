import sys,os
from pathlib import Path
import subprocess
import logging
import glob
import json
from Emedgene import Emedgene
from configurator import Config

class Sample:
	"""
	Sample object for patients. Eventually will be separated into Case Class and Sample Class
	"""
	def __init__(self, run_id, well, name="", bam_path="", fail_bam="", status={},HPOs="", config_file=os.path.expanduser(".myconf.json")):
		self.run_id		=	run_id #ie r84196_20250224_170647
		configs         = 	Config.from_path(config_file)
		
		self.refmaps_path	=	configs.Paths.ref_maps #This is required when writing the samplesheet
		self.tertiary_path = configs.Paths.tertiary_maps
		self.samplesheet_directory = configs.Paths.sample_sheet_path 
		self.runs_path	=	configs.Paths.run_path
		self.well		=	well
		self.sample_path=	self.runs_path + f"{run_id}/{well}"
		

		if len(bam_path) != 0:
			self.bam_path	=	bam_path
		else:
			self.bam_path	=	self.find_bam_path()

		#Optionally, we can provide a failed reads bam for TR calling
		if len(fail_bam) != 0:
			self.fail_bam	=	fail_bam
		else:
			self.fail_bam	=	self.find_fail_bam()


		self.barcode	=	self.bam_path.split("/")[-1].split("bc")[-1].removesuffix(".bam")
		#Sometimes, the name from sequencing is not compatible with the Emedgene name, so it must be given manually.
		#For example, we receive GMXXXX_redo or GMXXXX_new, while the Emedgene name should be GMXXXX 
		if len(name) != 0:
			self.name	=	name
		else:
			self.name	=	self.find_name()

		#If status is pre-defined, we don't need to investigate emedgene
		if len(status) != 0:
			self.case_status = status
			emg_case_id = "skip"
			self.phenotypes = ""

		else:
			emg_case_id	=	Emedgene(config_file=config_file).get_emg_id(self.name)
			
		#Does the patient belong to a trio, duo, or a singleton? Alse gender, family role and Affected status
		#if isinstance(self.emg_case_json,int):
		if emg_case_id == "":
			#If we get an int (error code) on Emedgene, we suppose it is likely a validation case, always singleton
			self.case_status = {"Status": "Singleton", "Role":"proband", "Gender":"null", "Affected": True}
			self.phenotypes = ""
		elif emg_case_id != "skip":
			emg_case_json	=	Emedgene(config_file=config_file).get_case_json(emg_case_id)
			self.case_status =	self.find_status(emg_case_json)

			pheno_case_id	=	Emedgene(config_file=config_file).get_pheno_id(json_file=(emg_case_json))
			#I'm removing this temporarily, while Phenotips is deprecated
			# if self.case_status["Affected"]:
			# 	self.phenotypes		=	Emedgene(config_file=config_file).qlin_import_HPO_request(pheno_case_id)
			# else:
			# 	self.phenotypes		=	""
			self.phenotypes		=	""
		
		#phenotype overrides if present
		if len(HPOs) != 0:
			self.phenotypes = HPOs

	def find_bam_path(self):
		"""
		Obtain the path for the BAM file of the sample. The name varies based on the time of sequencing
		Returns: Str (File path)
		"""
		bam_path = glob.glob(self.sample_path + "/hifi_reads/*bc*.bam")

		if len(bam_path) != 0 and os.path.isfile(bam_path[0]):
			return bam_path[0]
		else: 
			logging.warning(f"Could not find BAM path for sample {self.run_id}/{self.well}")
			sys.exit(1)

	def find_fail_bam(self):
		"""
		Obtain the failed reads . The name varies based on the time of sequencing
		Returns: Str (File path)
		"""
		fail_path = glob.glob(self.sample_path + "/fail_reads/*bc*.bam")

		if len(fail_path) != 0 and os.path.isfile(fail_path[0]):
			return fail_path[0]
		else: 
			logging.warning(f"Could not find failed BAM path for sample {self.run_id}/{self.well}")
			return ""


	def find_name(self):
		"""
		Obtain the sample name from its directory. The name can be extracted from a file in the pb_format folder.
		Returns: Str (name) or error
		"""
		grep_command = f"grep -o \"BioSample Name=\".*\"\" {self.sample_path}/pb_formats/*_s*.hifi_reads.bc*.consensusreadset.xml | cut -f2 -d'\"' | tr -d '\n'"
		grep_result = subprocess.run(grep_command, shell=True, capture_output=True, text=True)
		return grep_result.stdout

	def find_status(self,json_file):
		"""
		Obtain the status [Singleton, Duo, Trio] of the Sample.
		Also returns the role of Sample [Proband, father, mother], gender and affected status
		Requires the Emedgene json case
		Returns: Dict ({Status: [Singleton, Duo, Trio, Unknown],Role: [Proband, father, mother,"Unknown"], Gender: [Male,Female, null], Affected: [True, False,None]})
		"""
		if "patients" in json_file.keys():
			family_members = json_file["patients"]
			number_in_case = len(family_members)
			match number_in_case:
				case 1: status = "Singleton"
				case 2: status = "Duo"
				case 3: status = "Trio"
				case 4: 
					if "other" in family_members.keys() and len(family_members["other"]) == 0:
						status = "Trio"
					else:
						status = "Unknown"

				case _: status = "Unknown"
			
			role = "Unknown"
			gender = "null"
			affected = None

			for member in family_members.keys():
				if member == "other":
					continue
				if (type(family_members[member]) is dict) and ("fastq_sample" in family_members[member]):
					if member == "proband":
						proband_name = family_members[member]["fastq_sample"]
					if family_members[member]["fastq_sample"] == self.name:
						if role == "Unknown":
							role = member
							gender = family_members[member]["gender"]

							if len(family_members[member]["phenotypes"]) > 0:
								pheno_list = family_members[member]["phenotypes"][0]
							else:
								pheno_list = {"name": "Healthy"}

							#We take a look at the phenotypes to know if parent is affected
							#The actual phenotype list will be obtained from Phenotips (more up to date)
							if "name" in pheno_list.keys() and pheno_list["name"] == "Healthy":
								affected = False
							else:
								affected = True
						else:
							logging.warning(f"{self.name} was assigned roles more than once, check proper trio")
				else:
					logging.warning(f"The format of sample {self.name} does not correspond to expected format. See {self.name}_error.json")
					with open(f"{self.name}_error.json",'w') as fw:
						json.dump(json_file, fw, indent=4)
					sys.exit(1)

			if (role == "father" and gender == "Female") or (role == "mother" and gender == "Male"):
				logging.warning(f"Error, got role {role} and gender {gender} for patient {self.name}")
			if role == "Unknown" or gender =="null" or status == "Unknown":
				logging.warning(f"Patient status, role or gender could not be extracted from JSON file for patient {self.name}")
				print(f"Please see file {self.name}_error.json for more info")
				with open(f"{self.name}_error.json",'w') as fp:
					json.dump(json_file,fp,indent=4)

			if role == "father" or role == "mother":
				role += f" of {proband_name}"
				if affected:
					logging.warning(f"Be aware: Parent is affected")

			return {"Status": status, "Role": role, "Gender": gender, "Affected": affected}
		else:
			logging.warning(f"Patient {self.name} Emedgene JSON does not seem to contain patient info.")
			print(f"Please see file {self.name}_error.json for more info")
			with open(f"{self.name}_error.json",'w') as fp:
				json.dump(json_file,fp,indent=4)
			return {"Status": "Unknown", "Role":"Unknown", "Gender":"null","Affected": None}
		
	def write_singleton_samplesheet(self):
		"""
		Writes a json samplesheet in given directory
		This samplesheet will be used by the Pacbi WGS WDL
		the naming convention is: {run_id}_{well}_{sample_name}.json
		"""
		sample_dict={"humanwgs_singleton.sample_id": self.name,\
			"humanwgs_singleton.sex": (self.case_status["Gender"]).upper(),\
  			"humanwgs_singleton.hifi_reads": [self.bam_path],\
  			"humanwgs_singleton.fail_reads": [self.fail_bam],\
			"humanwgs_singleton.phenotypes": self.phenotypes,\
  			"humanwgs_singleton.ref_map_file": self.refmaps_path,\
			"humanwgs_singleton.tertiary_map_file": self.tertiary_path,\
  			"humanwgs_singleton.backend": "HPC"}
		
		sample_file= f"{self.samplesheet_directory}/{self.run_id}_{self.well}_{self.name}.json"
		print(f"Writing samplesheet to {sample_file}")
		with open(sample_file, 'w') as fw:
			json.dump(sample_dict, fw, indent=4)



	def __str__(self):
		return (f"{self.name};{self.well};{self.barcode};{self.run_id};{self.case_status['Gender']};{self.case_status['Status']};{self.case_status['Role']};{self.phenotypes}")