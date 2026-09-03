#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(optparse)
})

EC_PATTERN <- paste0(
  "(?<![A-Za-z0-9.-])",
  "\\d+\\.(?:\\d+|-)\\.(?:\\d+|-)\\.(?:\\d+|-)",
  "(?![A-Za-z0-9.-])"
)

EC_FIELD_ALIASES <- c(
  "ec",
  "ecnumber",
  "ecnumbers",
  "enzymecommission",
  "enzymecommissionnumber",
  "enzymenumber"
)

normalized_name <- function(name) {
  gsub("[^a-z0-9]+", "", tolower(as.character(name)))
}

candidate_field_names <- function(header_name) {
  requested <- normalized_name(header_name)
  candidates <- requested

  if (requested %in% EC_FIELD_ALIASES) {
    candidates <- unique(c(candidates, EC_FIELD_ALIASES))
  }

  candidates
}

resolve_field <- function(columns, header_name, source_label) {
  wanted <- candidate_field_names(header_name)
  normalized_columns <- vapply(columns, normalized_name, character(1))
  match_index <- which(normalized_columns %in% wanted)

  if (length(match_index) > 0) {
    return(columns[[match_index[[1]]]])
  }

  stop(
    sprintf(
      "Could not find EC column/key %s in %s. Available fields: %s",
      shQuote(header_name),
      source_label,
      paste(columns, collapse = ", ")
    ),
    call. = FALSE
  )
}

auto_resolve_ec_field <- function(columns) {
  normalized_columns <- vapply(columns, normalized_name, character(1))
  match_index <- which(normalized_columns %in% EC_FIELD_ALIASES)

  if (length(match_index) > 0) {
    return(columns[[match_index[[1]]]])
  }

  NULL
}

extract_ids <- function(value, allow_generic = TRUE) {
  if (is.null(value) || length(value) == 0) {
    return(character())
  }

  if (is.list(value) && !is.data.frame(value)) {
    return(character())
  }

  values <- as.character(value)
  ids <- character()

  for (text in values) {
    text <- trimws(text)

    if (
      is.na(text) ||
      !nzchar(text) ||
      tolower(text) %in% c("nan", "none", "null", "na", "n/a")
    ) {
      next
    }

    matched <- regmatches(text, gregexpr(EC_PATTERN, text, perl = TRUE))[[1]]
    matched <- matched[matched != ""]

    if (length(matched) > 0) {
      ids <- c(ids, matched)
      next
    }

    if (allow_generic) {
      tokens <- unlist(strsplit(text, "[;,|]", perl = TRUE), use.names = FALSE)
      tokens <- trimws(tokens)
      tokens <- tokens[nzchar(tokens)]
      ids <- c(ids, tokens)
    }
  }

  unique(ids)
}

recursively_extract_ecs <- function(value) {
  ids <- character()

  if (is.data.frame(value)) {
    for (column in names(value)) {
      ids <- c(ids, recursively_extract_ecs(value[[column]]))
    }
  } else if (is.list(value)) {
    for (item in value) {
      ids <- c(ids, recursively_extract_ecs(item))
    }
  } else {
    ids <- c(ids, extract_ids(value, allow_generic = FALSE))
  }

  unique(ids)
}

extract_json_field_values <- function(value, field_name) {
  ids <- character()
  wanted <- candidate_field_names(field_name)

  if (is.data.frame(value)) {
    for (key in names(value)) {
      nested_value <- value[[key]]

      if (normalized_name(key) %in% wanted) {
        if (is.list(nested_value) && !is.atomic(nested_value)) {
          ids <- c(ids, recursively_extract_ecs(nested_value))
        } else {
          ids <- c(ids, extract_ids(nested_value, allow_generic = TRUE))
        }
      }

      ids <- c(ids, extract_json_field_values(nested_value, field_name))
    }
  } else if (is.list(value)) {
    value_names <- names(value)

    for (i in seq_along(value)) {
      nested_value <- value[[i]]
      key <- if (!is.null(value_names) && nzchar(value_names[[i]])) value_names[[i]] else NULL

      if (!is.null(key) && normalized_name(key) %in% wanted) {
        if (is.list(nested_value)) {
          ids <- c(ids, recursively_extract_ecs(nested_value))
        } else {
          ids <- c(ids, extract_ids(nested_value, allow_generic = TRUE))
        }
      }

      ids <- c(ids, extract_json_field_values(nested_value, field_name))
    }
  }

  unique(ids)
}

extract_json_alias_values <- function(value) {
  ids <- character()

  if (is.data.frame(value)) {
    for (key in names(value)) {
      nested_value <- value[[key]]

      if (normalized_name(key) %in% EC_FIELD_ALIASES) {
        if (is.list(nested_value) && !is.atomic(nested_value)) {
          ids <- c(ids, recursively_extract_ecs(nested_value))
        } else {
          ids <- c(ids, extract_ids(nested_value, allow_generic = TRUE))
        }
      }

      ids <- c(ids, extract_json_alias_values(nested_value))
    }
  } else if (is.list(value)) {
    value_names <- names(value)

    for (i in seq_along(value)) {
      nested_value <- value[[i]]
      key <- if (!is.null(value_names) && nzchar(value_names[[i]])) value_names[[i]] else NULL

      if (!is.null(key) && normalized_name(key) %in% EC_FIELD_ALIASES) {
        if (is.list(nested_value)) {
          ids <- c(ids, recursively_extract_ecs(nested_value))
        } else {
          ids <- c(ids, extract_ids(nested_value, allow_generic = TRUE))
        }
      }

      ids <- c(ids, extract_json_alias_values(nested_value))
    }
  }

  unique(ids)
}

read_json_ids <- function(path, header_name = NULL) {
  data <- fromJSON(path, simplifyVector = FALSE)

  if (!is.null(header_name) && nzchar(header_name)) {
    ids <- extract_json_field_values(data, header_name)
    if (length(ids) > 0) {
      return(ids)
    }
  }

  ids <- extract_json_alias_values(data)
  if (length(ids) > 0) {
    return(ids)
  }

  recursively_extract_ecs(data)
}

infer_delimiter <- function(path) {
  connection <- file(path, open = "r", encoding = "UTF-8-BOM")
  on.exit(close(connection), add = TRUE)

  lines <- readLines(connection, n = 20, warn = FALSE)
  sample <- paste(lines, collapse = "\n")

  if (!nzchar(trimws(sample))) {
    return(",")
  }

  candidates <- c(",", "\t", ";")
  counts <- vapply(
    candidates,
    function(delim) {
      sum(lengths(regmatches(sample, gregexpr(delim, sample, fixed = TRUE))))
    },
    numeric(1)
  )

  if (max(counts) == 0) {
    extension <- tolower(tools::file_ext(path))
    return(if (extension %in% c("tsv", "txt")) "\t" else ",")
  }

  candidates[[which.max(counts)]]
}

read_tabular_file <- function(path, delimiter) {
  tryCatch(
    read.delim(
      path,
      sep = delimiter,
      header = TRUE,
      stringsAsFactors = FALSE,
      check.names = FALSE,
      quote = "\"",
      comment.char = "",
      na.strings = character(),
      fileEncoding = "UTF-8-BOM"
    ),
    error = function(exc) {
      stop(sprintf("Failed to parse %s: %s", basename(path), exc$message), call. = FALSE)
    }
  )
}

scan_tabular_columns_for_ecs <- function(df) {
  ids <- character()

  for (column in names(df)) {
    ids <- c(ids, extract_ids(df[[column]], allow_generic = FALSE))
  }

  unique(ids)
}

read_tabular_ids <- function(path, header_name = NULL) {
  delimiter <- infer_delimiter(path)
  df <- read_tabular_file(path, delimiter)

  if (!is.null(header_name) && nzchar(header_name)) {
    field <- resolve_field(names(df), header_name, basename(path))
    return(extract_ids(df[[field]], allow_generic = TRUE))
  }

  field <- auto_resolve_ec_field(names(df))

  if (!is.null(field)) {
    return(extract_ids(df[[field]], allow_generic = TRUE))
  }

  scan_tabular_columns_for_ecs(df)
}

read_ids <- function(path, header_name = NULL) {
  if (!file.exists(path) || dir.exists(path)) {
    stop(sprintf("Input file does not exist: %s", path), call. = FALSE)
  }

  extension <- tolower(tools::file_ext(path))

  if (extension == "json") {
    return(read_json_ids(path, header_name))
  }

  if (extension %in% c("csv", "tsv", "txt")) {
    return(read_tabular_ids(path, header_name))
  }

  stop(
    sprintf(
      "Unsupported file type '.%s'. Supported types: .csv, .tsv, .txt, .json",
      extension
    ),
    call. = FALSE
  )
}

load_data <- function(query_file, subject_dir, header_name = NULL) {
  query_ids <- read_ids(query_file, header_name)

  if (length(query_ids) == 0) {
    stop(sprintf("No usable IDs/ECs found in query input: %s", query_file), call. = FALSE)
  }

  if (!dir.exists(subject_dir)) {
    stop(sprintf("Subject input must be a directory: %s", subject_dir), call. = FALSE)
  }

  supported_extensions <- c("csv", "tsv", "txt", "json")
  paths <- sort(list.files(subject_dir, full.names = TRUE))
  subject_ids <- list()

  for (path in paths) {
    if (dir.exists(path)) {
      next
    }

    extension <- tolower(tools::file_ext(path))
    if (!(extension %in% supported_extensions)) {
      next
    }

    tryCatch(
      {
        ids <- read_ids(path, header_name)

        if (length(ids) > 0) {
          subject_ids[[basename(path)]] <- unique(ids)
        } else {
          message(sprintf("Skipped %s: no usable IDs/ECs found.", basename(path)))
        }
      },
      error = function(exc) {
        message(sprintf("Failed to read %s: %s", basename(path), exc$message))
      }
    )
  }

  list(query_ids = unique(query_ids), subject_ids = subject_ids)
}

evaluate_combination <- function(combination, query_ids, subject_ids) {
  combined <- character()

  for (filename in combination) {
    combined <- union(combined, subject_ids[[filename]])
  }

  covered <- intersect(combined, query_ids)
  ordered <- sort(combination)

  result <- as.list(ordered)
  names(result) <- paste0("file", seq_along(ordered))
  result$query_covered_count <- length(covered)
  result$total_ec_coverage <- length(combined)

  result
}

option_list <- list(
  make_option(
    c("-o", "--output"),
    type = "character",
    default = "ECOM_analysis.csv",
    help = "Output CSV filename [default: %default]"
  ),
  make_option(
    c("-t", "--threads"),
    type = "integer",
    default = 1,
    help = "Number of worker processes [default: %default]"
  ),
  make_option(
    c("-c", "--combination_size"),
    type = "integer",
    default = 5,
    help = "Number of subject files per combination [default: %default]"
  ),
  make_option(
    c("-n", "--header_name"),
    type = "character",
    default = NULL,
    help = paste(
      "Optional identifier field name for tabular inputs.",
      "When omitted, common EC fields are detected automatically.",
      "JSON files are resolved independently."
    )
  )
)

parser <- OptionParser(
  usage = "%prog [options] query_file subject_dir",
  description = paste(
    "ECOM: Enzyme Commission Overlap Modeler.",
    "Accepts CSV, UniProt TSV/TXT, and JSON input."
  ),
  option_list = option_list
)

parsed <- parse_args(parser, positional_arguments = TRUE)
options <- parsed$options
arguments <- parsed$args

if (length(arguments) != 2) {
  print_help(parser)
  stop("Expected query_file and subject_dir positional arguments.", call. = FALSE)
}

query_file <- arguments[[1]]
subject_dir <- arguments[[2]]

if (is.na(options$threads) || options$threads < 1) {
  stop("--threads must be at least 1.", call. = FALSE)
}

if (is.na(options$combination_size) || options$combination_size < 1) {
  stop("--combination_size must be at least 1.", call. = FALSE)
}

loaded <- load_data(query_file, subject_dir, options$header_name)
query_ids <- loaded$query_ids
subject_ids <- loaded$subject_ids
subject_files <- names(subject_ids)

if (length(subject_files) == 0) {
  stop("No usable subject files were found.", call. = FALSE)
}

if (length(subject_files) < options$combination_size) {
  stop(
    "Unable to process a combination number greater than the number of usable subject files present.",
    call. = FALSE
  )
}

combination_matrix <- combn(subject_files, options$combination_size)
combination_list <- lapply(
  seq_len(ncol(combination_matrix)),
  function(index) combination_matrix[, index]
)

worker_count <- min(options$threads, parallel::detectCores(logical = TRUE))

if (.Platform$OS.type == "windows" || worker_count == 1) {
  results <- lapply(
    combination_list,
    evaluate_combination,
    query_ids = query_ids,
    subject_ids = subject_ids
  )
} else {
  results <- parallel::mclapply(
    combination_list,
    evaluate_combination,
    query_ids = query_ids,
    subject_ids = subject_ids,
    mc.cores = worker_count
  )
}

ranked <- do.call(
  rbind,
  lapply(results, function(item) {
    as.data.frame(item, stringsAsFactors = FALSE, check.names = FALSE)
  })
)

ranked$query_covered_count <- as.integer(ranked$query_covered_count)
ranked$total_ec_coverage <- as.integer(ranked$total_ec_coverage)

ranked <- ranked[
  order(
    -ranked$query_covered_count,
    -ranked$total_ec_coverage
  ),
  ,
  drop = FALSE
]

ranked <- cbind(rank = seq_len(nrow(ranked)), ranked)
row.names(ranked) <- NULL

write.csv(
  ranked,
  file = options$output,
  row.names = FALSE,
  na = ""
)

field_mode <- if (!is.null(options$header_name) && nzchar(options$header_name)) {
  sprintf("explicit field %s", shQuote(options$header_name))
} else {
  "automatic EC-field detection"
}

cat(
  sprintf(
    paste0(
      "\nRun complete.\n",
      "Input mode: %s\n",
      "Query ECs/IDs: %d\n",
      "Usable subject files: %d\n",
      "Combinations ranked: %d\n",
      "Output: %s\n\n"
    ),
    field_mode,
    length(query_ids),
    length(subject_ids),
    nrow(ranked),
    options$output
  )
)
