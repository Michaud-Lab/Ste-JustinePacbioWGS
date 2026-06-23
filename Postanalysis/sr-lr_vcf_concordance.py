#!/usr/bin/env python3
"""
vcf_concordance.py — Cross-platform SNV concordance checker
Compares a PacBio/DeepVariant VCF against an Illumina/GATK VCF to verify
they likely originate from the same patient.

Usage:
	python vcf_concordance.py --vcf1 pacbio_dv.vcf.gz --vcf2 illumina_gatk.vcf.gz
	python vcf_concordance.py --vcf1 a.vcf --vcf2 b.vcf --min-gq 20 --min-dp 10 --output report.txt

Requirements:
	pip install cyvcf2 numpy
"""

import argparse
import sys
from collections import defaultdict

try:
	from cyvcf2 import VCF
	import numpy as np
except ImportError:
	sys.exit("Missing dependencies. Run:	pip install cyvcf2 numpy")


# ── Genotype helpers ──────────────────────────────────────────────────────────

def normalise_gt(gt_tuple):
	"""Return a frozenset of allele indices, or None if missing/uncallable."""
	if gt_tuple is None:
		return None
	alleles = [a for a in gt_tuple if a is not None and a >= 0]
	if len(alleles) < 2:
		return None
	return frozenset(alleles)			# {0,0}=hom-ref	{0,1}=het	{1,1}=hom-alt


def gt_label(gt_set):
	if gt_set is None:
		return "./."
	alleles = sorted(gt_set)
	if len(alleles) == 1:
		# hom call stored as a single-element set (e.g. frozenset({0}) or frozenset({1}))
		return f"{alleles[0]}/{alleles[0]}"
	return f"{alleles[0]}/{alleles[1]}"


def is_snv(ref, alts):
	"""True if ALL alt alleles are single-nucleotide substitutions."""
	return (
		len(ref) == 1
		and all(len(a) == 1 and a not in ('.', '*') for a in alts)
	)


# ── VCF loading ───────────────────────────────────────────────────────────────

def load_vcf(path, min_gq, min_dp, snv_only, pass_only, label):
	"""
	Parse a VCF and return a dict:
		{ (chrom, pos, ref, alt_tuple) : gt_frozenset }

	Filters applied per variant:
		- FILTER == PASS (or '.') if pass_only
		- SNV-only if snv_only
		- GQ >= min_gq	(skipped if field absent)
		- DP >= min_dp	(skipped if field absent)
	"""
	variants = {}
	counts = defaultdict(int)

	vcf = VCF(path)
	if not vcf.samples:
		sys.exit(f"[{label}] No samples found in {path}")

	# We always compare the FIRST sample in each VCF
	sample_name = vcf.samples[0]
	print(f"[{label}] sample	: {sample_name}")

	for variant in vcf:
		counts["total"] += 1

		# PASS filter
		if pass_only and variant.FILTER and variant.FILTER not in ("PASS", "."):
			counts["filtered_FILTER"] += 1
			continue

		# SNV-only
		alts = variant.ALT or []
		if snv_only and not is_snv(variant.REF, alts):
			counts["filtered_not_snv"] += 1
			continue

		# Genotype for sample 0
		gt_raw = variant.genotypes[0]			# e.g. [0, 1, True]
		gt = normalise_gt(gt_raw[:2])
		if gt is None:
			counts["filtered_missing_gt"] += 1
			continue

		# GQ filter
		try:
			gq = variant.format("GQ")[0][0]
			if gq is not None and not np.isnan(float(gq)) and float(gq) < min_gq:
				counts["filtered_GQ"] += 1
				continue
		except (TypeError, KeyError, IndexError):
			pass	# field absent — skip filter

		# DP filter
		try:
			dp = variant.format("DP")[0][0]
			if dp is not None and not np.isnan(float(dp)) and float(dp) < min_dp:
				counts["filtered_DP"] += 1
				continue
		except (TypeError, KeyError, IndexError):
			pass

		# Normalise chrom name (strip "chr" prefix for consistency)
		chrom = variant.CHROM.lstrip("chr")

		# Use first ALT only for multi-allelic sites (simplification)
		alt = alts[0] if alts else "."
		key = (chrom, variant.POS, variant.REF, alt)

		# Keep highest-GQ call if duplicate key
		if key not in variants:
			variants[key] = gt
			counts["kept"] += 1
		else:
			counts["duplicate_site"] += 1

	vcf.close()

	print(f"	[{label}] total variants read : {counts['total']:>10,}")
	print(f"	[{label}] kept after filters	: {counts['kept']:>10,}")
	for reason in ("filtered_FILTER", "filtered_not_snv","filtered_missing_gt", "filtered_GQ", "filtered_DP","duplicate_site"):
		if counts[reason]:
			print(f"[{label}]	dropped ({reason:<22}): {counts[reason]:>8,}")
	print()

	return variants, sample_name


# ── Concordance calculation ───────────────────────────────────────────────────

def compute_concordance(vars1, vars2):
	shared_keys = set(vars1) & set(vars2)

	concordant		= 0	# same genotype
	discordant_gt	 = 0	# same site, different genotype
	discordant_het_hom = 0	# specifically het vs hom-alt (common cross-platform issue)
	discordant_other	= 0

	gt_matrix = defaultdict(int)	# (gt1_label, gt2_label) → count

	for key in shared_keys:
		g1 = vars1[key]
		g2 = vars2[key]
		l1, l2 = gt_label(g1), gt_label(g2)
		gt_matrix[(l1, l2)] += 1

		if g1 == g2:
			concordant += 1
		else:
			discordant_gt += 1
			# Detect het/hom-alt swap specifically
			alleles1 = sorted(g1)
			alleles2 = sorted(g2)
			if (alleles1 == [0, 1] and alleles2 == [1, 1]) or \
				(alleles1 == [1, 1] and alleles2 == [0, 1]):
				discordant_het_hom += 1
			else:
				discordant_other += 1

	return {
		"n_vcf1"			: len(vars1),
		"n_vcf2"			: len(vars2),
		"shared"			: len(shared_keys),
		"concordant"		: concordant,
		"discordant_total" : discordant_gt,
		"discordant_het_hom" : discordant_het_hom,
		"discordant_other" : discordant_other,
		"gt_matrix"		: gt_matrix,
	}


# ── Interpretation ────────────────────────────────────────────────────────────

def interpret(res):
	"""
	Heuristic thresholds for cross-platform (PacBio DV vs Illumina GATK) comparisons.
	Same patient typically shows genotype concordance > 90 % on shared SNVs.
	"""
	shared = res["shared"]
	if shared < 100:
		return "INCONCLUSIVE", "red", "Too few shared sites to make a call."

	conc_rate = res["concordant"] / shared

	if conc_rate >= 0.90:
		verdict = "SAME PATIENT	✓"
		color	= "green"
		note	= (
			f"Genotype concordance of {conc_rate:.1%} is consistent with the same individual. "
			"Values between 90–98 % are normal for cross-platform comparisons due to "
			"platform-specific errors and representation differences."
		)
	elif conc_rate >= 0.75:
		verdict = "AMBIGUOUS	⚠"
		color	= "yellow"
		note	= (
			f"Concordance of {conc_rate:.1%} is lower than expected for the same patient "
			"but above random. Consider increasing quality filters (--min-gq, --min-dp), "
			"checking for chr-prefix mismatches, or re-normalising with bcftools norm."
		)
	else:
		verdict = "LIKELY DIFFERENT PATIENTS	✗"
		color	= "red"
		note	= (
			f"Concordance of {conc_rate:.1%} is consistent with different individuals. "
			"Unrelated individuals typically share < 60 % genotype concordance on heterozygous SNVs."
		)

	# Flag unusual het/hom discordance (common in low-coverage long reads)
	het_hom_frac = res["discordant_het_hom"] / max(res["discordant_total"], 1)
	if het_hom_frac > 0.5 and res["discordant_total"] > 50:
		note += (
			f"\n	⚠	{het_hom_frac:.0%} of discordant calls are het↔hom-alt swaps — "
			"this is typical of coverage differences between platforms, not a sample swap."
		)

	return verdict, color, note


# ── Report ────────────────────────────────────────────────────────────────────

ANSI = {"green": "\033[92m", "yellow": "\033[93m", "red": "\033[91m", "reset": "\033[0m"}

def report(res, sample1, sample2, vcf1_path, vcf2_path, output_path=None):
	shared = res["shared"]
	conc	= res["concordant"]
	disc	= res["discordant_total"]
	conc_rate = conc / max(shared, 1)
	jaccard	= shared / max(res["n_vcf1"] + res["n_vcf2"] - shared, 1)

	verdict, color, note = interpret(res)

	lines = [
		"=" * 62,
		"	VCF CROSS-PLATFORM CONCORDANCE REPORT",
		"=" * 62,
		f"	VCF 1	: {vcf1_path}",
		f"	sample : {sample1}",
		f"	VCF 2	: {vcf2_path}",
		f"	sample : {sample2}",
		"-" * 62,
		f"	Variants in VCF 1			 : {res['n_vcf1']:>10,}",
		f"	Variants in VCF 2			 : {res['n_vcf2']:>10,}",
		f"	Shared sites (intersection)	: {shared:>10,}",
		f"	Site Jaccard index			: {jaccard:>10.4f}",
		"-" * 62,
		f"	Concordant genotypes			: {conc:>10,}	({conc_rate:.2%})",
		f"	Discordant genotypes			: {disc:>10,}	({disc/max(shared,1):.2%})",
		f"	of which het↔hom-alt		: {res['discordant_het_hom']:>10,}",
		f"	of which other				: {res['discordant_other']:>10,}",
		"-" * 62,
	]

	# Genotype confusion matrix
	if res["gt_matrix"]:
		lines.append("	Genotype confusion matrix (VCF1 rows × VCF2 cols):")
		all_gts = sorted({g for pair in res["gt_matrix"] for g in pair})
		header	= "		" + "	".join(f"{g:>5}" for g in all_gts)
		lines.append(header)
		for g1 in all_gts:
			row = f"	{g1:>5} |"
			for g2 in all_gts:
				row += f"	{res['gt_matrix'].get((g1, g2), 0):>5}"
			lines.append(row)
		lines.append("-" * 62)

	lines += [
		f"	VERDICT: {verdict}",
		"",
		f"	{note}",
		"=" * 62,
	]

	text = "\n".join(lines)

	# Print with colour to terminal
	colour_text = text.replace(
		f"VERDICT: {verdict}",
		f"VERDICT: {ANSI[color]}{verdict}{ANSI['reset']}"
	)
	print(colour_text)

	if output_path:
		with open(output_path, "w") as f:
			f.write(text + "\n")
		print(f"\n	Report saved to: {output_path}")


# ── CLI ───────────────────────────────────────────────────────────────────────

def parse_args():
	p = argparse.ArgumentParser(
		description="Cross-platform VCF concordance checker (PacBio/DeepVariant vs Illumina/GATK)",
		formatter_class=argparse.ArgumentDefaultsHelpFormatter,
	)
	p.add_argument("--vcf1",		required=True, help="First VCF (e.g. PacBio/DeepVariant). Can be .vcf or .vcf.gz")
	p.add_argument("--vcf2",		required=True, help="Second VCF (e.g. Illumina/GATK). Can be .vcf or .vcf.gz")
	p.add_argument("--min-gq",	 type=float, default=20,	help="Minimum genotype quality (GQ)")
	p.add_argument("--min-dp",	 type=float, default=8,	help="Minimum read depth (DP)")
	p.add_argument("--snv-only",	action="store_true", default=True,
					help="Restrict to SNVs only (recommended for cross-platform)")
	p.add_argument("--no-snv-only", dest="snv_only", action="store_false",
					help="Include indels in comparison")
	p.add_argument("--pass-only",	action="store_true", default=True,
					help="Only use PASS/. variants")
	p.add_argument("--no-pass-only", dest="pass_only", action="store_false",
					help="Include non-PASS variants")
	p.add_argument("--output",	 default=None, help="Save text report to this file")
	return p.parse_args()


def main():
	args = parse_args()

	print(f"\nFilters applied: GQ >= {args.min_gq}	|	DP >= {args.min_dp}	"
			f"|	SNV-only = {args.snv_only}	|	PASS-only = {args.pass_only}\n")

	print("Loading VCF 1 ...")
	vars1, sname1 = load_vcf(args.vcf1, args.min_gq, args.min_dp,
								args.snv_only, args.pass_only, "VCF1")

	print("Loading VCF 2 ...")
	vars2, sname2 = load_vcf(args.vcf2, args.min_gq, args.min_dp,
								args.snv_only, args.pass_only, "VCF2")

	print("Computing concordance ...")
	res = compute_concordance(vars1, vars2)

	report(res, sname1, sname2, args.vcf1, args.vcf2, args.output)


if __name__ == "__main__":
	main()
