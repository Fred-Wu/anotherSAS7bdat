# anotherSAS7bdat

## Overview

anotherSAS7bdat reads SAS `.sas7bdat` files into R in configurable chunks using
the [ReadStat](https://github.com/WizardMac/ReadStat) C library by
[Evan Miller](https://www.evanmiller.org/). Each file is opened once, and reading
continues between chunks without restarting the parser. Each chunk is an R
data frame.

It also converts SAS files directly to one Parquet file with
`sas7bdat_to_parquet()`. Decoded values stay in native buffers and pass through
the Arrow C Data Interface to the optional **arrow** package, without
constructing intermediate R data frames or collecting the whole dataset.

## Installation

Install the development version from GitHub:

```r
# install.packages("remotes")
remotes::install_github("Fred-Wu/anotherSAS7bdat")
```

Source installation requires Rtools on Windows, or C++ build tools on macOS
and Linux.

For SAS-to-Parquet conversion, also install **arrow** (version 14.0.0 or later):

```r
install.packages("arrow")
```

## Usage

The package includes three example files generated with SAS 9.4:

- `example_uncompressed.sas7bdat`: uncompressed.
- `example_rle.sas7bdat`: RLE compression (`COMPRESS=CHAR`).
- `example_rdc.sas7bdat`: RDC compression (`COMPRESS=BINARY`).

Each contains the same 120 rows with numeric values, Unicode text, dates,
times, datetimes, column labels, and ordinary and special missing values.
Use any of these filenames in `system.file()` below. SAS is not needed to
read the bundled files.

### Reading into R

Both examples below read the entire file into `sas_data`, an R data frame.
The complete dataset and temporary chunks must fit in memory.

For faster binding of many chunks, use
[`data.table::rbindlist()`](https://rdatatable.gitlab.io/data.table/reference/rbindlist.html)
from the optional **data.table** package in place of `do.call(rbind, chunks)`.
It returns a `data.table`, which also inherits from `data.frame`.

Using `sas7bdat_read()`:

```r
library(anotherSAS7bdat)

path <- system.file("examples", "example_uncompressed.sas7bdat",
                    package = "anotherSAS7bdat")
chunks <- list()

sas7bdat_read(
  path,
  chunk_rows = 25,
  callback = function(data) {
    chunks[[length(chunks) + 1L]] <<- data
  }
)

sas_data <- do.call(rbind, chunks)
# Faster alternative with data.table installed:
# sas_data <- data.table::rbindlist(chunks, use.names = TRUE)
rm(chunks)
```

The callback stores each data frame in `chunks`; `rbind` combines them into
`sas_data`. The file closes automatically.

Using `sas7bdat_open()` and `sas7bdat_read_chunk()`:

```r
library(anotherSAS7bdat)

path <- system.file("examples", "example_rle.sas7bdat",
                    package = "anotherSAS7bdat")
reader <- sas7bdat_open(path, chunk_rows = 25)
chunks <- list()

repeat {
  data <- sas7bdat_read_chunk(reader)
  if (is.null(data)) break
  chunks[[length(chunks) + 1L]] <- data
}

sas7bdat_close(reader)

sas_data <- do.call(rbind, chunks)
# Faster alternative with data.table installed:
# sas_data <- data.table::rbindlist(chunks, use.names = TRUE)
rm(chunks)
```

The loop reads until `NULL` signals the end of the file, then closes the reader.
Use `sas7bdat_info(reader)` to inspect its current status and reading information.

See `?sas7bdat_read` for the reader functions and their settings.

### Converting SAS to Parquet

`sas7bdat_to_parquet()` streams batches into one Parquet file. `chunk_rows`
limits rows per batch; an optional `chunk_bytes` sets an approximate decoded
byte target. The output directory must exist, and existing files are never
overwritten. The completed file is published only after conversion succeeds.

```r
library(anotherSAS7bdat)

path <- system.file("examples", "example_rle.sas7bdat",
                    package = "anotherSAS7bdat")
output <- tempfile(fileext = ".parquet")

result <- sas7bdat_to_parquet(
  path,
  output,
  chunk_rows = 100000L,
  compression = "snappy",
  progress = FALSE
)

result$rows       # 120
result$completed  # TRUE

# Read back the small example file.
sas_data <- arrow::read_parquet(output)
head(sas_data)
unlink(output)
```

Reading back with `arrow::read_parquet()` collects the output into R. For large
output files, use `arrow::open_dataset(output)` to query the file without
collecting the entire dataset.

Recognized SAS dates and datetimes are converted by default; SAS times retain
double seconds and are restored as `hms` when read into R with arrow. Column
labels and SAS formats are retained in metadata. Set `dates = FALSE` to keep
the original SAS numeric units. Ordinary and special numeric missing values
become Parquet nulls; set `missing_tags = TRUE` to retain special codes in
additional `<name>__sas_missing` columns.

Set `progress = TRUE` to show a progress bar; it is enabled by default in
interactive R sessions. See `?sas7bdat_to_parquet` for all conversion settings
and metadata details.

### Experimental parallel Parquet writing

On `feature/parquet-multithread-wide`, `sas7bdat_to_parquet()` also accepts
`writer_threads = NULL` (original writer), `1L` (buffered serial writer),
or `4L` and higher (buffered parallel column encoding). This experimental
path requires a **custom Arrow R build** with additional buffered-writer
bindings; the standard CRAN `arrow` package does not expose them.

For patching instructions, correctness tests and benchmarks on wide datasets,
see [tools/README-threaded-parquet.md](tools/README-threaded-parquet.md).
The default path remains unchanged.

## Development Note

This package was developed with assistance from GPT models using OpenAI's
Codex. The overall feature design and logic decisions are mine; GPT models
were used to generate and iterate on the implementation.
