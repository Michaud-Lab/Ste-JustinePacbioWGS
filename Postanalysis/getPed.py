import json, sys
import os.path

#Small script to generate PED format pedigree:
#https://github.com/brentp/slivar/wiki/pedigree-file
#PED file example:


# p054    25-01142-T1     25-01144-T1     25-01146-T1     1       2
# p054    25-01146-T1                     2       1
# p054    25-01144-T1                     1       1

#Input trioName and json samplesheet (in the WGS-WDL format) to infer ped data
#This input json file is expected to follow the format of the WGS-WDL V3:
#https://github.com/PacificBiosciences/HiFi-human-WGS-WDL/blob/main/workflows/family.inputs.json

def main():
	
	if len(sys.argv) < 3:
		print("Usage: python script.py <trio_name_list> <trio_sample_sheet>")
		sys.exit(1)

	trioName = sys.argv[1]
	if not os.path.isfile(sys.argv[2]):
		print(f"Could not find file {sys.argv[2]}")
		sys.exit(1)

	with open(sys.argv[2],'r') as fileJson:
		sampleSheet = json.load(fileJson)['humanwgs_family.family']

	probandID = sampleSheet['samples'][0]['sample_id']
	probandGender = sampleSheet['samples'][0]['sex']
	if probandGender == 'Male' or probandGender == 'MALE' or probandGender == 'M':
		probandCode = '1'
	elif probandGender == 'Female' or probandGender == 'FEMALE' or probandGender == 'F':
		probandCode = '2'
	else:
		print(f"Could not infer gender {probandGender}")
		sys.exit(1)

	if "father_id" in sampleSheet['samples'][0].keys():
		fatherID = sampleSheet['samples'][0]['father_id']
		fatherLine = f"""
{trioName}\t{fatherID}\t\t\t1\t1"""
	else:
		fatherID = ""
		fatherLine = ""
	if "mother_id" in sampleSheet['samples'][0].keys():	
		motherID = sampleSheet['samples'][0]['mother_id']
		motherLine = f"""
{trioName}\t{motherID}\t\t\t2\t1"""
	else:
		motherID = ""
		motherLine = ""
# Tabs in order: FamilyID, SampleID, PaternalID, MaternalID, Sex, Phenotype
	with open(f"{trioName}.ped",'w') as pedFile:
		pedFile.write(
f"""{trioName}\t{probandID}\t{fatherID}\t{motherID}\t{probandCode}\t2{motherLine}{fatherLine}
""")
	print(f"{trioName}.ped")

if __name__ == "__main__":
    main()