# ECOM: Enzyme Commission Overlap Modeler

ECOM is a Python (R version available!) command-line tool for identifying combinations of subject Enzyme Commission numbers that best overlap with a query set of Enzyme Commission numbers.

Given one query CSV and a directory of subject CSV files, ECOM evaluates all possible file combinations of a chosen size and ranks them by:

1. How many query EC numbers are covered
2. How many total unique EC numbers are represented

## Features

- Python and R implementations
- Reads Enzyme Commission numbers from CSV, TSV, TXT (including UniProt exports), and BV-BRC Pathway JSON files
- Accepts mixed input formats within the same analysis
- Flexible EC column matching (for example `EC number`, `ec_number`, and common aliases)
- Automatically extracts EC identifiers from delimited fields and embedded text
- Compares one query file against many subject files
- Evaluates combinations of subject files
- Ranks combinations by query coverage and total EC diversity
- Supports multiprocessing/parallel execution for faster analysis
- Outputs ranked results as a CSV file

## Implementations

### Python

**Requirements**

- Python 3
- pandas

Install dependencies:

```bash
pip install pandas
```

### R

**Requirements**

- R
- jsonlite
- parallel

Install dependencies:

```r
install.packages(c("jsonlite", "parallel"))
```

## Usage

### Python

```bash
python ecom.py QUERY_FILE SUBJECT_DIR -n HEADER_NAME [options]
```

### R

```bash
Rscript ecom.R QUERY_FILE SUBJECT_DIR -n HEADER_NAME [options]
```

## Arguments

| Argument | Description |
|---|---|
| `QUERY_CSV` | Query input file (.csv, .tsv, .txt, or .json) |
| `SUBJECT_CSV_DIR` | Directory containing subject .csv, .tsv, .txt, and/or .json files |
| `-n`, `--header_name` | Name of the CSV column containing EC numbers |

## Optional Parameters

| Option | Default | Description |
|---|---:|---|
| `-o`, `--output` | `ECOM_analysis` | Output CSV filename |
| `-t`, `--threads` | `1` | Number of CPU threads to use |
| `-c`, `--combination_size` | `5` | Number of subject files per combination |

## Examples

```bash
python ecom.py query.tsv subjects/ -n "EC number" -o results.csv -t 4 -c 3

Rscript ecom.R query.json subjects/ -n ec_number -o results.csv -t 4 -c 3
```

## Input Format

Supported input formats:

- CSV
- TSV / TXT (including UniProt exports)
- JSON (record list or wrapper object)

The requested EC field is matched flexibly, so names such as `EC number` and `ec_number` are treated as equivalent.

Example:

```csv
EC_Number
1.1.1.1
2.7.11.1
3.5.4.4
```

## Output Format

```csv
rank,file1,file2,file3,query_covered_count,total_ec_coverage
1,sampleA.csv,sampleB.csv,sampleC.csv,42,95
2,sampleA.csv,sampleD.csv,sampleE.csv,39,101
```

## Output Columns

| Column | Description |
|---|---|
| `rank` | Rank of the file combination |
| `file1`, `file2`, etc. | Subject files included in the combination |
| `query_covered_count` | Number of query EC numbers covered by the combination |
| `total_ec_coverage` | Total number of unique EC numbers in the combination |

## How Ranking Works

ECOM ranks each subject-file combination by two criteria:

1. **Query coverage**: the number of query EC numbers found in the combined subject files
2. **Total EC coverage**: the total number of unique EC numbers across the combined subject files

Combinations with higher query coverage are ranked first. If two combinations cover the same number of query EC numbers, the combination with greater total EC coverage is ranked higher.

## Notes

- Files without the specified EC-number column are skipped.
- Empty subject files are ignored.
- The combination size cannot be greater than the number of valid subject files.
- Larger combination sizes and larger subject directories can greatly increase runtime.


## AI-Assisted Development

Portions of this software and its documentation were created with the assistance of large language models (LLMs). AI-generated content was reviewed, tested, and modified as necessary by the author. The author assumes full responsibility for the accuracy and functionality of the final software.

## License



## Citation

If you use ECOM in your research, please cite this repository.
