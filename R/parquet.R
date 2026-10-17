#' Convert SAS data directly to Parquet
#'
#' Stream a SAS file into one Parquet file without constructing R data frames
#' or R character vectors. Requires the optional arrow package.
#'
#' @inheritParams sas7bdat_read
#' @param output Path to a new local Parquet file. The parent directory must
#'   exist. Existing files are never overwritten.
#' @param compression Parquet compression codec, for example `"snappy"`,
#'   `"zstd"`, or `"uncompressed"`, supported by your arrow installation.
#' @param dates Whether to convert recognized SAS dates and datetimes to
#'   Parquet date and UTC timestamp types. SAS times retain double seconds and
#'   are restored as `hms` when imported into R with arrow.
#'   Set to `FALSE` to retain all original SAS numeric values.
#' @param missing_tags Whether to retain SAS special missing tags in additional
#'   character columns. The default, `FALSE`, keeps the original column set.
#'   Set to `TRUE` to add one `<name>__sas_missing`
#'   column for each numeric source column, with unique names when necessary.
#'   These contain `"a"` through `"z"` or `"_"` for special missing values,
#'   and null otherwise. Numeric missing values themselves become Parquet nulls.
#'   With `FALSE`, ordinary and special missing values both become nulls;
#'   their missing status is preserved but special codes are discarded.
#' @param progress A logical value. Set to `TRUE` to show a console progress
#'   bar, or `FALSE` to hide it. The default, `interactive()`, shows the bar
#'   in interactive R sessions and hides it when running via `Rscript`.
#'   Progress uses the SAS row count and updates after each batch is written.
#'   It reaches 100% only after the completed output file is published.
#' @param writer_threads Optional experimental Parquet writer thread count. `NULL`
#'   (default) retains the existing sequential `WriteTable()` path. `1L` uses
#'   buffered `WriteRecordBatch()` with serial column encoding; values above 1
#'   enable parallel column encoding. Non-`NULL` settings require the patched
#'   Arrow R bindings described in `tools/README-threaded-parquet.md`.
#'   Changes to Arrow's global CPU thread pool are restored on exit.
#' @return An invisible list containing `path`, `rows`, `chunks`, `completed`,
#'   and `missing_tag_columns`, a named mapping from numeric source columns to
#'   their tag columns (empty when `missing_tags = FALSE`).
#' @details
#' Native decoded batches are exported through the Arrow C Data Interface.
#' R coordinates the writer and holds small schema and batch handles; dataset
#' values remain in native buffers. The persistent SAS reader, column selection,
#' UTF-8 decoding, adaptive buffer sizing, and bounded read-ahead are shared
#' with `sas7bdat_read()`. Arrow is needed only for this conversion function.
#'
#' Each decoded batch becomes a Parquet row group, with at most `chunk_rows`
#' rows. An explicit `chunk_bytes` can produce smaller groups; the default
#' `NULL` lets the row limit control batch sizes. Native output batches are
#' released after each write; the whole dataset is never collected.
#'
#' With `dates = TRUE`, recognized SAS dates become Parquet dates (days since
#' 1970-01-01), and datetimes become UTC timestamps rounded to the nearest
#' microsecond. Fractional dates and out-of-range temporal values cause an
#' error. SAS times remain double seconds, preserving negative times, values
#' beyond 24 hours, and fractional seconds. R metadata restores their `hms`
#' class and `HH:MM:SS` display when read with `arrow::read_parquet()` or
#' converted from an Arrow table to an R data frame. With `dates = FALSE`, all numeric
#' values retain their original SAS units and double precision, including
#' sub-microsecond datetime values.
#'
#' File metadata retains `sas.table_name`, `sas.label`, and `sas.encoding`.
#' Each field retains `sas.label`, `sas.format`, `sas.type`, `sas.units`, and
#' `sas.missing_tags`; tag fields identify their source in `sas.missing_for`.
#' R metadata also restores column `label` and `format.sas` attributes and the
#' file label on import. Other Parquet clients see times as double seconds.
#' Inspect the schema metadata with
#' `arrow::read_parquet(output, as_data_frame = FALSE)$schema`.
#'
#' Conversion writes a temporary file in the output directory and publishes
#' it only after reading and writing finish successfully. Errors and interrupts
#' close the reader and remove the incomplete temporary output. Empty SAS files
#' produce a valid empty Parquet file with the selected schema.
#' @export
#' @examples
#' if (requireNamespace("arrow", quietly = TRUE)) {
#'   path <- system.file("examples", "example_rle.sas7bdat",
#'                       package = "anotherSAS7bdat")
#'   output <- tempfile(fileext = ".parquet")
#'   sas7bdat_to_parquet(path, output)
#'   data <- arrow::read_parquet(output)
#'   unlink(output)
#' }
sas7bdat_to_parquet <- function(path, output, chunk_rows = 100000L,
                               chunk_bytes = NULL, columns = NULL,
                               encoding = NULL, dates = TRUE,
                               compression = "snappy", missing_tags = FALSE,
                               progress = interactive(), writer_threads = NULL) {
  if (!requireNamespace("arrow", quietly = TRUE)) {
    stop("Install the optional arrow package to convert to Parquet.", call. = FALSE)
  }
  scalar_string(output, "output")
  scalar_string(compression, "compression")
  if (!is.logical(missing_tags) || length(missing_tags) != 1L || is.na(missing_tags)) {
    stop("`missing_tags` must be TRUE or FALSE.", call. = FALSE)
  }
  if (!is.logical(progress) || length(progress) != 1L || is.na(progress)) {
    stop("`progress` must be TRUE or FALSE.", call. = FALSE)
  }
  if (!is.null(writer_threads)) {
    if (!is.numeric(writer_threads) || length(writer_threads) != 1L ||
        is.na(writer_threads) || !is.finite(writer_threads) ||
        writer_threads < 1 || writer_threads != floor(writer_threads) ||
        writer_threads > .Machine$integer.max) {
      stop("`writer_threads` must be NULL or a positive integer.", call. = FALSE)
    }
    writer_threads <- as.integer(writer_threads)
    arrow_writer_properties <- get("ParquetArrowWriterProperties", asNamespace("arrow"))
    patched <- "use_threads" %in% names(formals(arrow_writer_properties$create)) &&
      all(c("NewBufferedRowGroup", "WriteRecordBatch") %in%
          names(arrow::ParquetFileWriter$public_methods))
    if (!patched) {
      stop("`writer_threads` requires the experimental Arrow R buffered writer bindings; see tools/README-threaded-parquet.md.", call. = FALSE)
    }
    if (writer_threads > 1L) {
      previous_threads <- arrow::set_cpu_count(writer_threads)
      on.exit(arrow::set_cpu_count(previous_threads), add = TRUE)
    }
  }
  directory <- normalizePath(dirname(output), winslash = "/", mustWork = TRUE)
  output <- file.path(directory, basename(output))
  if (file.exists(output)) stop("`output` already exists.", call. = FALSE)

  reader <- sas7bdat_open(path, chunk_rows, chunk_bytes, columns, encoding, dates)
  temporary <- tempfile(".sas-parquet-", tmpdir = directory)
  writer <- sink <- progress_bar <- NULL
  on.exit({
    sas7bdat_close(reader)
    if (!is.null(writer)) try(writer$Close(), silent = TRUE)
    if (!is.null(sink)) try(sink$close(), silent = TRUE)
    unlink(temporary)
    if (!is.null(progress_bar)) close(progress_bar)
  }, add = TRUE)

  info <- sas7bdat_info(reader)
  fields <- info$columns$name
  numeric <- info$columns$type == "double"
  tags <- rep("", length(fields))
  if (missing_tags && any(numeric)) {
    names <- make.unique(c(fields, paste0(fields[numeric], "__sas_missing")))
    tags[numeric] <- names[-seq_along(fields)]
  }
  schema <- arrow::Schema$import_from_c(native_arrow_schema(reader$ptr, dates, tags))
  schema <- parquet_r_metadata(schema, dates)
  properties <- arrow::ParquetWriterProperties$create(
    schema$names, version = "2.6", compression = compression
  )
  sink <- arrow::FileOutputStream$create(temporary)
  if (is.null(writer_threads)) {
    writer <- arrow::ParquetFileWriter$create(schema, sink, properties = properties)
  } else {
    arrow_properties <- arrow_writer_properties$create(use_threads = writer_threads > 1L)
    writer <- arrow::ParquetFileWriter$create(
      schema, sink, properties = properties, arrow_properties = arrow_properties)
  }
  if (progress) progress_bar <- utils::txtProgressBar(min = 0, max = 1, style = 3)
  rows <- chunks <- 0
  repeat {
    exported <- native_arrow_next(reader$ptr, reader$chunk_rows, dates, tags)
    if (is.null(exported)) break
    batch <- arrow::RecordBatch$import_from_c(exported$array, exported$schema)
    if (is.null(writer_threads)) {
      writer$WriteBatch(batch, chunk_size = reader$chunk_rows)
    } else {
      writer$NewBufferedRowGroup()
      writer$WriteRecordBatch(batch)
    }
    rows <- rows + batch$num_rows
    chunks <- chunks + 1
    if (!is.null(progress_bar)) {
      utils::setTxtProgressBar(progress_bar, min(rows / max(1, info$rows_total), 0.99))
    }
    rm(batch, exported)
    # These buffers are native allocations, invisible to R's allocation-driven
    # GC trigger. Collect each consumed batch and temporary native buffers
    # to bound memory independently of the number of batches.
    invisible(gc(verbose = FALSE))
  }
  writer$Close()
  writer <- NULL
  sink$close()
  sink <- NULL
  sas7bdat_close(reader)
  if (file.exists(output) || !file.rename(temporary, output)) {
    stop("Could not publish the completed Parquet file at `output`.", call. = FALSE)
  }
  if (!is.null(progress_bar)) utils::setTxtProgressBar(progress_bar, 1)
  mapping <- tags[nzchar(tags)]
  names(mapping) <- fields[nzchar(tags)]
  invisible(list(path = output, rows = rows, chunks = chunks, completed = TRUE,
                 missing_tag_columns = mapping))
}

# Attach column attributes once to the writer schema. Only schema metadata is
# constructed in R; all dataset values continue through the native batch path.
parquet_r_metadata <- function(schema, dates) {
  columns <- lapply(schema$fields, function(field) {
    metadata <- field$metadata
    attributes <- list()
    if (!is.null(metadata[["sas.label"]]) && nzchar(metadata[["sas.label"]])) {
      attributes$label <- metadata[["sas.label"]]
    }
    if (!is.null(metadata[["sas.format"]]) && nzchar(metadata[["sas.format"]])) {
      attributes$format.sas <- metadata[["sas.format"]]
    }
    if (dates && identical(metadata[["sas.type"]], "time")) {
      attributes$class <- c("hms", "difftime")
      attributes$units <- "secs"
    }
    if (length(attributes)) list(attributes = attributes) else NULL
  })
  names(columns) <- schema$names
  metadata <- schema$metadata
  metadata$r <- list(columns = columns)
  if (nzchar(metadata[["sas.label"]])) {
    metadata$r$attributes <- list(label = metadata[["sas.label"]])
  }
  schema$WithMetadata(metadata)
}
