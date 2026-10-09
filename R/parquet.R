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
#'   Parquet date and UTC timestamp types. SAS times remain double seconds.
#'   Set to `FALSE` to retain all original SAS numeric values.
#' @param missing_tags Whether to retain SAS special missing tags in additional
#'   character columns. The default, `TRUE`, adds one `<name>__sas_missing`
#'   column for each numeric source column, with unique names when necessary.
#'   These contain `"a"` through `"z"` or `"_"` for special missing values,
#'   and null otherwise. Numeric missing values themselves become Parquet nulls.
#'   Set to `FALSE` to omit the tag columns and discard the distinction between
#'   ordinary and special missing values.
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
#' beyond 24 hours, and fractional seconds. With `dates = FALSE`, all numeric
#' values retain their original SAS units and double precision, including
#' sub-microsecond datetime values.
#'
#' File metadata retains `sas.table_name`, `sas.label`, and `sas.encoding`.
#' Each field retains `sas.label`, `sas.format`, `sas.type`, `sas.units`, and
#' `sas.missing_tags`; tag fields identify their source in `sas.missing_for`.
#' These are Arrow schema metadata, rather than R column attributes. Inspect
#' them with `arrow::read_parquet(output, as_data_frame = FALSE)$schema`.
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
                               compression = "snappy", missing_tags = TRUE) {
  if (!requireNamespace("arrow", quietly = TRUE)) {
    stop("Install the optional arrow package to convert to Parquet.", call. = FALSE)
  }
  scalar_string(output, "output")
  scalar_string(compression, "compression")
  if (!is.logical(missing_tags) || length(missing_tags) != 1L || is.na(missing_tags)) {
    stop("`missing_tags` must be TRUE or FALSE.", call. = FALSE)
  }
  directory <- normalizePath(dirname(output), winslash = "/", mustWork = TRUE)
  output <- file.path(directory, basename(output))
  if (file.exists(output)) stop("`output` already exists.", call. = FALSE)

  reader <- sas7bdat_open(path, chunk_rows, chunk_bytes, columns, encoding, dates)
  temporary <- tempfile(".sas-parquet-", tmpdir = directory)
  writer <- sink <- NULL
  on.exit({
    sas7bdat_close(reader)
    if (!is.null(writer)) try(writer$Close(), silent = TRUE)
    if (!is.null(sink)) try(sink$close(), silent = TRUE)
    unlink(temporary)
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
  properties <- arrow::ParquetWriterProperties$create(
    schema$names, version = "2.6", compression = compression
  )
  sink <- arrow::FileOutputStream$create(temporary)
  writer <- arrow::ParquetFileWriter$create(schema, sink, properties = properties)
  rows <- chunks <- 0
  repeat {
    exported <- native_arrow_next(reader$ptr, reader$chunk_rows, dates, tags)
    if (is.null(exported)) break
    batch <- arrow::RecordBatch$import_from_c(exported$array, exported$schema)
    writer$WriteBatch(batch, chunk_size = reader$chunk_rows)
    rows <- rows + batch$num_rows
    chunks <- chunks + 1
    rm(batch, exported)
    # These buffers are native allocations, invisible to R's allocation-driven
    # GC trigger. Collect each consumed batch, including WriteBatch's temporary
    # table wrapper, to bound memory independently of the number of batches.
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
  mapping <- tags[nzchar(tags)]
  names(mapping) <- fields[nzchar(tags)]
  invisible(list(path = output, rows = rows, chunks = chunks, completed = TRUE,
                 missing_tag_columns = mapping))
}
