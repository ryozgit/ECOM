#!/usr/bin/env python3

import argparse
import csv
import json
import re
import sys
from itertools import combinations
from multiprocessing import Pool, cpu_count
from pathlib import Path

import pandas as pd


query_ecs = None
subject_ecs = None

EC_PATTERN = re.compile(
    r"(?<![A-Za-z0-9.-])"
    r"\d+\.(?:\d+|-)\.(?:\d+|-)\.(?:\d+|-)"
    r"(?![A-Za-z0-9.-])"
)

EC_FIELD_ALIASES = {
    "ec",
    "ecnumber",
    "ecnumbers",
    "enzymecommission",
    "enzymecommissionnumber",
    "enzymenumber",
}


def initialize_worker(worker_query_ecs, worker_subject_ecs):
    global query_ecs, subject_ecs
    query_ecs = worker_query_ecs
    subject_ecs = worker_subject_ecs


def evaluate_combination(combination):
    combined = set()
    covered = set()

    for filename in combination:
        ecs = subject_ecs[filename]
        combined.update(ecs)
        covered.update(ecs & query_ecs)

    ordered = sorted(combination)

    return {
        **{f"file{i + 1}": filename for i, filename in enumerate(ordered)},
        "query_covered_count": len(covered),
        "total_ec_coverage": len(combined),
    }


def normalized_name(name):
    return re.sub(r"[^a-z0-9]+", "", str(name).casefold())


def candidate_field_names(header_name):
    requested = normalized_name(header_name)
    candidates = {requested}

    if requested in EC_FIELD_ALIASES:
        candidates.update(EC_FIELD_ALIASES)

    return candidates


def resolve_field(columns, header_name, source_label):
    wanted = candidate_field_names(header_name)

    for column in columns:
        if normalized_name(column) in wanted:
            return column

    raise ValueError(
        f"Could not find EC column/key {header_name!r} in {source_label}. "
        f"Available fields: {list(columns)}"
    )


def auto_resolve_ec_field(columns):
    for column in columns:
        if normalized_name(column) in EC_FIELD_ALIASES:
            return column

    return None


def extract_ids(value, allow_generic=True):
    if value is None:
        return set()

    if isinstance(value, (dict, list, tuple, set)):
        return set()

    text = str(value).strip()

    if not text or text.casefold() in {"nan", "none", "null", "na", "n/a"}:
        return set()

    matched_ecs = set(EC_PATTERN.findall(text))
    if matched_ecs:
        return matched_ecs

    if not allow_generic:
        return set()

    return {
        token.strip()
        for token in re.split(r"[;,|]", text)
        if token.strip()
    }


def recursively_extract_ecs(value):
    ids = set()

    if isinstance(value, dict):
        for nested_value in value.values():
            ids.update(recursively_extract_ecs(nested_value))

    elif isinstance(value, (list, tuple, set)):
        for item in value:
            ids.update(recursively_extract_ecs(item))

    else:
        ids.update(extract_ids(value, allow_generic=False))

    return ids


def collect_record_keys(records):
    keys = []
    seen = set()

    for record in records:
        if not isinstance(record, dict):
            continue

        for key in record:
            if key not in seen:
                keys.append(key)
                seen.add(key)

    return keys


def extract_json_field_values(value, field_name):
    ids = set()
    wanted = candidate_field_names(field_name)

    if isinstance(value, dict):
        for key, nested_value in value.items():
            if normalized_name(key) in wanted:
                if isinstance(nested_value, (dict, list, tuple, set)):
                    ids.update(recursively_extract_ecs(nested_value))
                else:
                    ids.update(extract_ids(nested_value, allow_generic=True))

            ids.update(extract_json_field_values(nested_value, field_name))

    elif isinstance(value, (list, tuple, set)):
        for item in value:
            ids.update(extract_json_field_values(item, field_name))

    return ids


def extract_json_alias_values(value):
    ids = set()

    if isinstance(value, dict):
        for key, nested_value in value.items():
            if normalized_name(key) in EC_FIELD_ALIASES:
                if isinstance(nested_value, (dict, list, tuple, set)):
                    ids.update(recursively_extract_ecs(nested_value))
                else:
                    ids.update(extract_ids(nested_value, allow_generic=True))

            ids.update(extract_json_alias_values(nested_value))

    elif isinstance(value, (list, tuple, set)):
        for item in value:
            ids.update(extract_json_alias_values(item))

    return ids


def read_json_ids(path, header_name=None):
    with path.open("r", encoding="utf-8-sig") as handle:
        data = json.load(handle)

    if header_name:
        ids = extract_json_field_values(data, header_name)
        if ids:
            return ids

    ids = extract_json_alias_values(data)
    if ids:
        return ids

    return recursively_extract_ecs(data)


def infer_delimiter(path):
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        sample = handle.read(8192)

    if not sample.strip():
        return ","

    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=",\t;")
        return dialect.delimiter
    except csv.Error:
        return "\t" if path.suffix.casefold() in {".tsv", ".txt"} else ","


def scan_tabular_columns_for_ecs(df):
    ids = set()

    for column in df.columns:
        for value in df[column]:
            ids.update(extract_ids(value, allow_generic=False))

    return ids


def read_tabular_ids(path, header_name=None):
    delimiter = infer_delimiter(path)

    df = pd.read_csv(
        path,
        sep=delimiter,
        dtype=str,
        keep_default_na=False,
        encoding="utf-8-sig",
    )

    if header_name:
        field = resolve_field(df.columns, header_name, path.name)

        ids = set()
        for value in df[field]:
            ids.update(extract_ids(value, allow_generic=True))

        return ids

    field = auto_resolve_ec_field(df.columns)

    if field is not None:
        ids = set()
        for value in df[field]:
            ids.update(extract_ids(value, allow_generic=True))

        return ids

    return scan_tabular_columns_for_ecs(df)


def read_ids(path, header_name=None):
    path = Path(path)

    if not path.is_file():
        raise ValueError(f"Input file does not exist: {path}")

    suffix = path.suffix.casefold()

    if suffix == ".json":
        return read_json_ids(path, header_name)

    if suffix in {".csv", ".tsv", ".txt"}:
        return read_tabular_ids(path, header_name)

    raise ValueError(
        f"Unsupported file type {path.suffix!r}. "
        "Supported types: .csv, .tsv, .txt, .json"
    )


def load_data(query_file, subject_dir, header_name=None):
    query_path = Path(query_file)
    subject_path = Path(subject_dir)

    query_ids = read_ids(query_path, header_name)

    if not query_ids:
        raise ValueError(f"No usable IDs/ECs found in query input: {query_path}")

    if not subject_path.is_dir():
        raise ValueError(f"Subject input must be a directory: {subject_path}")

    subject_ids = {}
    supported_extensions = {".csv", ".tsv", ".txt", ".json"}

    for path in sorted(subject_path.iterdir()):
        if not path.is_file():
            continue

        if path.suffix.casefold() not in supported_extensions:
            continue

        try:
            ids = read_ids(path, header_name)

            if ids:
                subject_ids[path.name] = ids
            else:
                print(
                    f"Skipped {path.name}: no usable IDs/ECs found.",
                    file=sys.stderr,
                )

        except Exception as exc:
            print(f"Failed to read {path.name}: {exc}", file=sys.stderr)

    return query_ids, subject_ids


def main():
    parser = argparse.ArgumentParser(
        description=(
            "ECOM: Enzyme Commission Overlap Modeler. "
            "Accepts CSV, UniProt TSV/TXT, and JSON input."
        )
    )

    parser.add_argument(
        "query_file",
        help="Query input file (.csv, .tsv, .txt/UniProt, or .json).",
    )

    parser.add_argument(
        "subject_dir",
        help=(
            "Directory containing subject .csv, .tsv, .txt, "
            "and/or .json files."
        ),
    )

    parser.add_argument(
        "-o",
        "--output",
        default="ECOM_analysis.csv",
        help="Output CSV filename. Default: ECOM_analysis.csv",
    )

    parser.add_argument(
        "-t",
        "--threads",
        type=int,
        default=1,
        help="Number of worker processes. Default: 1",
    )

    parser.add_argument(
        "-c",
        "--combination_size",
        type=int,
        default=5,
        help="Number of subject files per combination. Default: 5",
    )

    parser.add_argument(
        "-n",
        "--header_name",
        required=False,
        default=None,
        help=(
            "Optional identifier field name for tabular inputs. "
            "When omitted, common EC column names are detected automatically. "
            "JSON files are resolved independently and may use different keys."
        ),
    )

    args = parser.parse_args()

    if args.threads < 1:
        parser.error("--threads must be at least 1.")

    if args.combination_size < 1:
        parser.error("--combination_size must be at least 1.")

    try:
        loaded_query_ecs, loaded_subject_ecs = load_data(
            args.query_file,
            args.subject_dir,
            args.header_name,
        )
    except Exception as exc:
        parser.error(str(exc))

    subject_files = list(loaded_subject_ecs)

    if not subject_files:
        sys.exit("No usable subject files were found.")

    if len(subject_files) < args.combination_size:
        sys.exit(
            "Unable to process a combination number greater than the number "
            "of usable subject files present."
        )

    parallel_workers = min(args.threads, cpu_count())

    with Pool(
        parallel_workers,
        initializer=initialize_worker,
        initargs=(loaded_query_ecs, loaded_subject_ecs),
    ) as pool:
        results = list(
            pool.imap_unordered(
                evaluate_combination,
                combinations(subject_files, args.combination_size),
            )
        )

    df = pd.DataFrame(results)

    ranked = (
        df.sort_values(
            ["query_covered_count", "total_ec_coverage"],
            ascending=[False, False],
        )
        .reset_index(drop=True)
    )

    ranked.index += 1
    ranked.to_csv(args.output, index_label="rank")

    field_mode = (
        f"explicit field {args.header_name!r}"
        if args.header_name
        else "automatic EC-field detection"
    )

    print(
        f"\nRun complete.\n"
        f"Input mode: {field_mode}\n"
        f"Query ECs/IDs: {len(loaded_query_ecs)}\n"
        f"Usable subject files: {len(loaded_subject_ecs)}\n"
        f"Combinations ranked: {len(ranked)}\n"
        f"Output: {args.output}\n"
    )


if __name__ == "__main__":
    main()
