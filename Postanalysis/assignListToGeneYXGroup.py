import os
import argparse
from GeneYX import GeneYX
import pandas as pd
#We have separate groups to which each sample must be assigned
#This script will assign a given list of samples to a group, if they are part of the full GeneYX list

if __name__ == "__main__":
	parser = argparse.ArgumentParser(
		prog = 'assignListToGeneYXGroup.py',
		usage = "python3 %(prog)s [-l list_of_names_to_assign] [-f csv_export_of_geneYX_vcf_full_list] [-g group to assign (validation, prag, decode, controle)] [--config config_file (optional)]",	
		description='Assigns a group to a list of sample on GeneYX.')
	parser.add_argument('-l', '--list',help='list of samples to be assigned, separated by newlines',required=True) 
	parser.add_argument('-f', '--full', nargs='?',help='Up to date csv export of all VCFs on GeneYX',const='Postanalysis/geneYXnamesList.csv', default='Postanalysis/geneYXnamesList.csv')
	parser.add_argument('-g', '--group',help='The group to which the samples should be assigned to',required=True)
	parser.add_argument('--config', nargs='?', const=None, default=None, help='Config file path (default env var WGS_CONFIG_FILE)')
	#parser.print_help()
	args = parser.parse_args()
	if not args.config:
		args.config = os.environ.get('WGS_CONFIG_FILE')
	if not args.config:
		parser.error("No explicit config file given (--config) and default config var WGS_CONFIG_FILE is not set. You can set one with 'export WGS_CONFIG_FILE=<path to config file>'")

	latest_geneyx_list = pd.read_csv(args.full,names=["ID","Subject"])
	given_group_list = pd.read_csv(args.list,names=["Subject"])

	#Obtain the vcf names from the geneYX list using the subject name as Key
	merged_df = latest_geneyx_list.merge(given_group_list,how='inner',on=["Subject"],indicator=True)[["ID","Subject"]]
	merged_df.drop_duplicates(inplace=True)
	merged_list = merged_df.loc[:,'ID'].values


	GeneYX(args.config).group_assign(args.group,merged_list)