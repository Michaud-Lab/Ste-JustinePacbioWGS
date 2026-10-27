#!/usr/bin/env python3
"""Replace the "Variant IDs" column of an SVTopo index.html with gene names
overlapping each region, looked up in an Ensembl GFF3 annotation file.

Usage:
    python3 annotate_svtopo_genes.py --html index.html --gff3 ensembl.GRCh38.101.reformatted.gff3.gz [--js app.js]
"""
import argparse
import gzip
import json
from bisect import bisect_right


def load_genes(gff3_path):
	genes_by_chrom = {}
	opener = gzip.open if gff3_path.endswith(".gz") else open
	with opener(gff3_path, "rt") as fh:
		for line in fh:
			if not line or line.startswith("#"):
				continue
			fields = line.rstrip("\n").split("\t")
			if len(fields) < 9 or fields[2] != "gene":
				continue
			chrom, start, end, attributes = fields[0], fields[3], fields[4], fields[8]
			name = None
			for kv in attributes.split(";"):
				if kv.startswith("Name="):
					name = kv[len("Name="):]
					break
				if kv.startswith("gene_name="):
					name = kv[len("gene_name="):]
					break
			if name is None:
				continue
			genes_by_chrom.setdefault(chrom, []).append((int(start), int(end), name))
	for chrom, genes in genes_by_chrom.items():
		genes.sort(key=lambda g: g[0])
	return genes_by_chrom


def _candidates_for_chrom(genes_by_chrom, chrom):
	if chrom in genes_by_chrom:
		return genes_by_chrom[chrom]
	alt = chrom[3:] if chrom.startswith("chr") else "chr" + chrom
	return genes_by_chrom.get(alt, [])


def genes_overlapping(genes_by_chrom, chrom, start, end):
	candidates = _candidates_for_chrom(genes_by_chrom, chrom)
	if not candidates:
		return []
	starts = [g[0] for g in candidates]
	# every gene starting after "end" cannot overlap [start, end]
	last = bisect_right(starts, end)
	seen = set()
	names = []
	for gstart, gend, name in candidates[:last]:
		if gend >= start and name not in seen:
			seen.add(name)
			names.append(name)
	return names


def annotate_html(html_path, genes_by_chrom):
	with open(html_path, "r") as fh:
		content = fh.read()

	decoder = json.JSONDecoder()
	for varname in ("data", "unique_data"):
		marker = "const {} = ".format(varname)
		start_idx = content.index(marker)
		value_start = start_idx + len(marker)
		rows, value_end = decoder.raw_decode(content, value_start)
		for row in rows:
			chrom, start, end = row.get("chrom"), row.get("start"), row.get("end")
			if chrom is None or start is None or end is None:
				continue
			row["variant_ids"] = genes_overlapping(genes_by_chrom, chrom, start, end)
		new_value = json.dumps(rows, separators=(", ", ": "))
		content = content[:value_start] + new_value + content[value_end:]

	content = content.replace("Variant IDs", "Genes").replace("Variant ID", "Gene")
	with open(html_path, "w") as fh:
		fh.write(content)


def relabel_app_js(js_path):
	with open(js_path, "r") as fh:
		content = fh.read()
	content = content.replace("Variant IDs", "Genes").replace("Variant ID", "Gene")
	with open(js_path, "w") as fh:
		fh.write(content)


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--html", required=True, help="SVTopo index.html to annotate in place")
	parser.add_argument("--gff3", required=True, help="Ensembl GFF3(.gz) annotation file")
	parser.add_argument("--js", help="SVTopo js/app.js to relabel in place (optional)")
	args = parser.parse_args()

	genes_by_chrom = load_genes(args.gff3)
	annotate_html(args.html, genes_by_chrom)
	if args.js:
		relabel_app_js(args.js)


if __name__ == "__main__":
	main()
