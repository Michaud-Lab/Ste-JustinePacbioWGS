"""
extractFamilies.py
--------------------
Reads Feuil1 (samples) and Familles (existing families), then:
1. Selects ToConfirm rows not yet assigned to a family (Trio column is NaN).
2. Skips rows where 'etude' is empty/NaN.
3. Applies etude-based rules:
   - "Volet LR PRAG -" / "prag"			→ Trio expected; require proband
   - "Volet LR PRAG - duo" / "prag duo"	→ Duo expected; require proband
   - "Decodeur"							 → Trio or Duo; require proband
   - "Validation PacBio +" / "Validation"  → Singleton proband only; parents
											 referencing these probands are skipped
   - "Contrôle parents" / "ControleParent"
	 / "Controle parent"				   → parent rows only; attached to
											  their proband's family (if proband
											  is non-singleton etude)
   - "Not on sharepoint"				   → treat as Singleton proband
   - Any other non-empty etude			 → include if has proband, warn
4. Families MUST have a proband. Members whose proband is not in the dataset
   are written to a separate "incomplete" report and NOT assigned a family.
5. Assigns new family names "p{N}" continuing from the highest existing number.
6. Writes new rows into Familles and updates the Trio column in Feuil1.

Input: either an Excel file (-x) with Feuil1 and Familles sheets,
	   or two separate CSVs (--feuil1 and --familles).
"""

import argparse
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

import pandas as pd

# ── etude normalisation ───────────────────────────────────────────────────────
ETUDE_MAP = {
	"volet lr prag -":		"potential trio",
	"prag":				   "potential trio",
	"volet lr prag - duo":	"duo",
	"prag duo":			   "duo",
	"decodeur":			   "decodeur",
	"validation pacbio +":	"potential trio",
	"validation":			 "potential trio",
	"contrôle parents":	   "potential trio",
	"controleparent":		 "potential trio",
	"controle parent":		"potential trio",
	"not on sharepoint":	  "singleton",
}


def normalise_etude(raw):
	if pd.isna(raw):
		return None
	return ETUDE_MAP.get(str(raw).strip().lower(), "other")


def load_inputs(args):
	"""Return (df_feuil, df_fam) from either an xlsx file or two CSV paths."""
	if args.xlsx:
		xlsx = pd.ExcelFile(args.xlsx)
		df_feuil = xlsx.parse("Feuil1",   dtype=str)
		df_fam   = xlsx.parse("Familles", dtype=str)
	else:
		df_feuil = pd.read_csv(args.feuil1,   sep=";", dtype=str)
		df_fam   = pd.read_csv(args.familles,  sep=";", dtype=str)

	df_feuil.columns = df_feuil.columns.str.strip()
	df_fam.columns   = df_fam.columns.str.strip()
	return df_feuil, df_fam


def extract_families(df_feuil, df_fam):
	"""Core logic. Returns (df_feuil_out, df_fam_out, skipped_rows)."""

	# ── Next family number ─────────────────────────────────────────────────────
	existing_nums = []
	for f in df_fam["Famille"].dropna():
		m = re.search(r"(\d+)", str(f))
		if m:
			existing_nums.append(int(m.group(1)))
	next_family_num = (max(existing_nums) + 1) if existing_nums else 1

	# ── Select candidates ──────────────────────────────────────────────────────
	mask = (df_feuil["sing_trio_duo"] == "ToConfirm") & (df_feuil["Trio"].isna())
	candidates = df_feuil[mask].copy()
	candidates = candidates.drop_duplicates(subset=["PatientID", "Role"])
	candidates["_etude_cat"] = candidates["etude"].apply(normalise_etude)

	skipped_no_etude = candidates[candidates["_etude_cat"].isna()].copy()
	candidates = candidates[candidates["_etude_cat"].notna()].copy()

	print(f"Candidates (after etude filter): {len(candidates)}")
	print(f"Skipped (empty etude):		   {len(skipped_no_etude)}")

	# ── Parse relationships ────────────────────────────────────────────────────
	probands			 = {}
	parent_of			= defaultdict(list)
	skipped_unrecognised = []

	for _, row in candidates.iterrows():
		role	  = str(row.get("Role", "")).strip() if pd.notna(row.get("Role")) else ""
		pid	   = str(row["PatientID"]).strip()
		etude_cat = row["_etude_cat"]

		if etude_cat == "singleton":
			if role.lower() == "proband":
				probands[pid] = row
			else:
				skipped_unrecognised.append(
					(pid, role, row.get("etude", ""), "parent row in singleton etude — skipped")
				)
			continue

		if role.lower() in ("proband", "unknown"):
			probands[pid] = row
		else:
			m = re.match(r"^(father|mother|parent|sibling)\s+of\s+(.+)$", role, re.IGNORECASE)
			if m:
				proband_ref = m.group(2).strip()
				parent_of[proband_ref].append(row)
			else:
				skipped_unrecognised.append(
					(pid, role, row.get("etude", ""), "unrecognised role")
				)

	# ── Build families ─────────────────────────────────────────────────────────
	all_proband_ids = set(probands.keys()) | set(parent_of.keys())
	families   = []
	incomplete = []
	assigned   = set()

	for pb_id in sorted(all_proband_ids):
		if pb_id in assigned:
			continue
		assigned.add(pb_id)

		if pb_id not in probands:
			for p in parent_of.get(pb_id, []):
				incomplete.append({
					"PatientID": p["PatientID"],
					"Role":	  p.get("Role", ""),
					"etude":	 p.get("etude", ""),
					"reason":	f"proband '{pb_id}' not found in dataset",
				})
			continue

		proband_row   = probands[pb_id]
		proband_etude = str(proband_row.get("_etude_cat", "")).strip()

		# if proband_etude == "singleton":
		#	 for p in parent_of.get(pb_id, []):
		#		 skipped_unrecognised.append((
		#			 p["PatientID"],
		#			 p.get("Role", ""),
		#			 p.get("etude", ""),
		#			 f"proband '{pb_id}' has singleton etude — parent excluded",
		#		 ))
		#	 members = [proband_row]
		# else:
		members = [proband_row] + parent_of.get(pb_id, [])

		n = len(members)
		if proband_etude == "singleton" or n == 1:
			family_type = "Singleton"
		elif n == 2:
			family_type = "Duo"
		elif n == 3:
			family_type = "Trio"
		else:
			family_type = f"Family-{n}"

		families.append({
			"family_name":	None,
			"family_type":	family_type,
			"etude_cat":  	proband_etude,
			"members":	 	members,
			"proband_id":	pb_id,
		})

	for fam in families:
		if fam["family_type"] != "Singleton":
			fam["family_name"] = f"p{next_family_num:03d}"
			next_family_num += 1

	# ── Report ─────────────────────────────────────────────────────────────────
	trios   = sum(1 for f in families if f["family_type"] == "Trio")
	duos	= sum(1 for f in families if f["family_type"] == "Duo")
	singles = sum(1 for f in families if f["family_type"] == "Singleton")
	other   = len(families) - trios - duos - singles

	print(f"\n✅ {len(families)} new families: {trios} trios, {duos} duos, {singles} singletons, {other} other")
	for fam in families:
		if fam["family_type"] != "Singleton":
			member_ids = [str(m["PatientID"]) for m in fam["members"]]
			print(f"  {fam['family_name']} ({fam['family_type']}, etude={fam['etude_cat']}): {member_ids}")

	if incomplete:
		print(f"\n⚠  {len(incomplete)} rows skipped — proband missing:")
		for row in incomplete:
			print(f"   {row['PatientID']} ({row['Role']}) | etude={row['etude']} | {row['reason']}")

	if skipped_unrecognised:
		print(f"\n⚠  {len(skipped_unrecognised)} rows skipped:")
		for pid, role, etude, reason in skipped_unrecognised:
			print(f"   PatientID={pid!r}  Role={role!r}  etude={etude!r}  ({reason})")

	if len(skipped_no_etude):
		print(f"\nℹ  {len(skipped_no_etude)} rows skipped — empty etude (in skipped_report.csv)")

	# ── Build new Familles rows ────────────────────────────────────────────────
	familles_run_col = next(
		(c for c in df_fam.columns if "Red" in c or "Incomplete" in c), None
	)

	new_fam_rows = []
	for fam in families:
		if fam["family_type"] != "Singleton":
			for member in fam["members"]:
				row_dict = {
					"Famille":		  fam["family_name"],
					"ID":			   member["PatientID"],
					"Cell":			 member.get("Cell", ""),
					"Barcode":		  member.get("Barcode", ""),
					"Sex":			  member.get("Real Gender", ""),
					"Type_Famille":	 fam["family_type"],
					"formatted_role":   member.get("formatted_role", ""),
					"HPO":			  member.get("HPO", ""),
					"Pipeline Version": member.get("Pipeline Version", ""),
				}
				if familles_run_col:
					row_dict[familles_run_col] = member.get("Run", "")
				new_fam_rows.append(row_dict)

	df_fam_out = pd.concat(
		[df_fam, pd.DataFrame(new_fam_rows)],
		ignore_index=True, sort=False,
	)

	# ── Update Trio column in Feuil1 ──────────────────────────────────────────
	pid_to_family = {
		str(m["PatientID"]).strip(): fam["family_name"]
		for fam in families
		for m in fam["members"]
	}

	df_feuil_out = df_feuil.copy()
	for idx, row in df_feuil_out.iterrows():
		pid = str(row["PatientID"]).strip()
		if pid in pid_to_family and pd.isna(row["Trio"]):
			df_feuil_out.at[idx, "Trio"] = pid_to_family[pid]

	# ── Collate skipped rows ───────────────────────────────────────────────────
	skipped_rows = list(incomplete)
	for pid, role, etude, reason in skipped_unrecognised:
		skipped_rows.append({"PatientID": pid, "Role": role, "etude": etude, "reason": reason})
	for _, row in skipped_no_etude.iterrows():
		skipped_rows.append({
			"PatientID": row["PatientID"],
			"Role":	  row.get("Role", ""),
			"etude":	 row.get("etude", ""),
			"reason":	"empty etude — skipped",
		})

	return df_feuil_out, df_fam_out, skipped_rows


if __name__ == "__main__":
	parser = argparse.ArgumentParser(
		prog="extractFamilies.py",
		usage=(
			"python3 %(prog)s "
			"(-x xlsx | --feuil1 feuil1.csv --familles familles.csv) "
			"[-o output_dir]"
		),
		description=(
			"Assign new family names to unclassified samples in Feuil1, "
			"then append the new families to Familles. "
			"Accepts either an Excel file (-x) containing both sheets, "
			"or two separate CSV files (--feuil1 / --familles)."
		),
	)

	parser.add_argument(
		"-x", "--xlsx",
		help="Excel file containing 'Feuil1' and 'Familles' sheets.",
	)
	parser.add_argument(
		"-f1","--feuil1",
		help="Feuil1 CSV (semicolon-separated). Required when -x is not used.",
	)
	parser.add_argument(
		"-f2","--fam","--familles",
		help="Familles CSV (semicolon-separated). Required when -x is not used.",
	)
	parser.add_argument(
		"-o", "--output",
		nargs="?", const=".", default=".",
		help="Output directory for updated CSVs and skipped report (default: current dir).",
	)

	args = parser.parse_args()

	# Validate: need either --xlsx or both --feuil1 and --familles
	if args.xlsx:
		if not os.path.isfile(args.xlsx):
			print(f"Error: Excel file not found: {args.xlsx}", file=sys.stderr)
			sys.exit(1)
	elif args.feuil1 and args.familles:
		for path, label in ((args.feuil1, "--feuil1"), (args.familles, "--familles")):
			if not os.path.isfile(path):
				print(f"Error: {label} file not found: {path}", file=sys.stderr)
				sys.exit(1)
	else:
		parser.error("Provide either -x/--xlsx or both --feuil1 and --familles.")

	out_dir = Path(args.output)
	out_dir.mkdir(parents=True, exist_ok=True)

	df_feuil, df_fam = load_inputs(args)
	df_feuil_out, df_fam_out, skipped_rows = extract_families(df_feuil, df_fam)

	feuil1_out   = out_dir / "Feuil1_updated.tsv"
	familles_out = out_dir / "Familles_updated.tsv"
	skipped_out  = out_dir / "skipped_report.tsv"

	df_feuil_out.to_csv(feuil1_out,   sep="\t", index=False)
	df_fam_out.to_csv(  familles_out, sep="\t", index=False)
	pd.DataFrame(skipped_rows).to_csv(skipped_out, sep="\t", index=False)

	print(f"\n📄 Feuil1 saved	→ {feuil1_out}")
	print(f"📄 Familles saved  → {familles_out}")
	print(f"📄 Skipped report  → {skipped_out}")
