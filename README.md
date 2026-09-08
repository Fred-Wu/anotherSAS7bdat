# anotherSAS7bdat

## Overview

anotherSAS7bdat reads SAS `.sas7bdat` files into R in configurable chunks using
the [ReadStat](https://github.com/WizardMac/ReadStat) C library by
[Evan Miller](https://www.evanmiller.org/). Each file is opened once, and reading
continues between chunks without restarting the parser. Each chunk is an R
data frame.

## Installation

Install the development version from GitHub:

```r
# install.packages("remotes")
remotes::install_github("Fred-Wu/anotherSAS7bdat")
```

Source installation requires Rtools on Windows, or C++ build tools on macOS
and Linux.

## Usage

The package includes three example files generated with SAS 9.4:

- `example_uncompressed.sas7bdat`: uncompressed.
- `example_rle.sas7bdat`: RLE compression (`COMPRESS=CHAR`).
- `example_rdc.sas7bdat`: RDC compression (`COMPRESS=BINARY`).

Each contains the same 120 rows with numeric values, Unicode text, dates,
times, datetimes, column labels, and ordinary and special missing values.
Use any of these filenames in `system.file()` below. SAS is not needed to
read the bundled files.

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

See `?sas7bdat_read` for all five functions and their settings.

## Development Note

This package was developed with assistance from GPT models using OpenAI's
Codex. The overall feature design and logic decisions are mine; GPT models
were used to generate and iterate on the implementation.
