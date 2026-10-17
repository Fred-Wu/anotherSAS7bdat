# Experimental multithreaded Parquet writing

Branch: feature/parquet-multithread-wide

## Overview

The default sas7bdat_to_parquet() path remains unchanged. Stock Arrow R's
ParquetFileWriter$WriteBatch() converts a RecordBatch to a Table and calls
WriteTable(). Arrow C++ writes each column sequentially with WriteTable().
Buffered WriteRecordBatch() can use Arrow's parallel column encoder when
ArrowWriterProperties::set_use_threads(true) is enabled.

**Stock Arrow R does not expose these APIs.** This experiment needs an
experimental custom Arrow R build using:
tools/patches/arrow-r-threaded-parquet.patch

The current native ReadStat reader, Arrow C Data Interface, SAS metadata,
single-file output, cleanup and progress handling are preserved.

## Patch Apache Arrow R

Apply the patch from the root of an Apache Arrow C++/R source checkout
matched to the upstream main sources inspected in October 2026:

~~~sh
git apply --check /path/to/anotherSAS7bdat/tools/patches/arrow-r-threaded-parquet.patch
git apply /path/to/anotherSAS7bdat/tools/patches/arrow-r-threaded-parquet.patch
cd r
Rscript data-raw/codegen.R
~~~

Rebuild and install the custom Arrow R package with compatible Arrow C++
headers and libraries. See https://arrow.apache.org/docs/r/articles/developers/setup.html

Code generation updates r/src/arrowExports.cpp and r/R/arrowExports.R.
Rebuilding without code generation is insufficient. A stock CRAN Arrow R
binary will not provide the new writer methods.

The patch adds only R bindings for existing Arrow C++ methods:
- ArrowWriterProperties::Builder::set_use_threads(bool)
- parquet::arrow::FileWriter::NewBufferedRowGroup()
- parquet::arrow::FileWriter::WriteRecordBatch()

The internal ParquetArrowWriterProperties R6 class is not exported from the
arrow namespace. The experimental function obtains it from the namespace;
the public API is not assumed to have a chained builder.

## Install the experiment

~~~r
remotes::install_github("Fred-Wu/anotherSAS7bdat@feature/parquet-multithread-wide")
~~~

## Usage

~~~r
library(anotherSAS7bdat)
sas7bdat_to_parquet(path, "baseline.parquet", writer_threads = NULL, progress = FALSE)
sas7bdat_to_parquet(path, "buffered-1.parquet", writer_threads = 1L, progress = FALSE)
sas7bdat_to_parquet(path, "buffered-4.parquet", writer_threads = 4L, progress = FALSE)
~~~

- NULL (default): existing sequential WriteTable() path.
- 1L: buffered WriteRecordBatch() with serial column encoding.
- 2L, 4L, 8L: buffered column encoding using Arrow's CPU thread pool.

The function restores the previous global Arrow CPU-pool size on exit.
Do not change the thread pool while another concurrent Arrow task runs.
Each decoded batch becomes one buffered row group; one Parquet file is created.

For repeated measurements, with an actual *wide* SAS input:

~~~sh
Rscript tools/benchmark-threaded-parquet.R input.sas7bdat output_directory 100000 3
~~~

Use the same input and settings and compare total elapsed time, output size,
peak memory, numeric and string values and schema metadata. Test narrow
and wide datasets separately. Run testthat::test_local() for correctness.

## Upstream

- https://github.com/apache/arrow/issues/50866 — Python parallel writer request
- https://github.com/apache/arrow/issues/36280 — direct RecordBatch writer request
- https://github.com/apache/arrow/blob/main/cpp/src/parquet/arrow/writer.cc

## Limitations

This is experimental and requires a custom Arrow R installation. It does
not add a duplicate Arrow C++ dependency to anotherSAS7bdat. The code has
not yet been compiled and benchmarked in this environment. Threading may
provide little improvement for disk-bound workloads and increases peak
native memory because row-group buffers are retained for column-parallel work.
