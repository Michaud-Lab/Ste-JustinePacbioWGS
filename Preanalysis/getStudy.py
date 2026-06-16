import pandas as pd
import argparse
import sys

def get_study_info(main_csv_path, specimen_list_path):
	"""
	Reads a main CSV and a list of specimens, then prints selected columns
	for the union of specimens found in both sources.

	Args:
		main_csv_path (str): Path to the main CSV file.
		specimen_list_path (str): Path to a line-separated file of specimen names.
	"""
	try:
		# Read the main CSV file
		df = pd.read_csv(main_csv_path)

		# Get the set of all specimen identifiers from the main CSV
		all_specimens_in_csv = set(df["Identifiant : Specimen"].dropna())

		# Create a DataFrame from the list of specimens to be used as the left side of the join
		#specimens_to_find_df = pd.DataFrame(specimens_from_file, columns=["Identifiant : Specimen"])
		specimens_to_find_df = pd.read_csv(specimen_list_path, names=["Identifiant : Specimen"], header=None)

		# Perform a left join. The order of the keys from the left frame is preserved.
		filtered_df = pd.merge(specimens_to_find_df, df, on="Identifiant : Specimen", how="left", sort=False)

		filtered_df = filtered_df.drop_duplicates(subset=["Identifiant : Specimen"], keep="last")
		for index, row in filtered_df.iterrows():
			# Decodeur samples start with 'HSJ'
			
			if row["Identifiant : Specimen"].startswith("HSJ") :	
				filtered_df.at[index,"Cohorte"] = "Decodeur"

		# Define the columns to be printed
		columns_to_print = [
			"Identifiant : Specimen",
			"Identifiant : probant",
			"Identifiant père",
			"Identifiant mère",
			"Commentaires",
			"Cohorte"
		]

		# Select and print the required columns to stdout
		result_df = filtered_df[columns_to_print]
		result_df.to_csv(sys.stdout, index=False)
		print("------Only cohorts------:")
		only_cohort = filtered_df["Cohorte"]
		print(f"Total specimens in list file: {specimens_to_find_df.shape[0]}")

		print(f"Lines in filtered list: {only_cohort.shape[0]}")
		only_cohort.to_csv(sys.stdout, index=False)

	except FileNotFoundError as e:
		print(f"Error: File not found - {e}", file=sys.stderr)
		sys.exit(1)
	except KeyError as e:
		print(f"Error: Column not found in CSV - {e}. Please check the CSV header.", file=sys.stderr)
		sys.exit(1)
	except Exception as e:
		print(f"An unexpected error occurred: {e}", file=sys.stderr)
		sys.exit(1)

if __name__ == "__main__":
	parser = argparse.ArgumentParser(
		prog = 'getStudy.py',
		usage = "python3 %(prog)s [-s lineSeparated_id_list] [-p pragmatiq_csv ]",	
		description="Extracts study information for a given list of specimens."
	)
	parser.add_argument(
		"-s",help="Path to a file containing a line-separated list of identifier for which you need the study",
		required=True
	)
	parser.add_argument(
		"-p",help="Path to a pragmatiq csv downloaded from the Sharepoint",
		required=True
	)

	args = parser.parse_args()
	main_csv_file = args.p
	specimen_list = args.s
	get_study_info(main_csv_file, specimen_list)