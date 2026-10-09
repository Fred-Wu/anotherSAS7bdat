# Run from the repository root:
# Rscript tools/benchmark-direct-parquet.R input.sas7bdat library-path [iterations]
# Uses identical row limits, Snappy compression, one file, and double-second
# time columns. Input should contain numeric, text, date, datetime and time data.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) >= 2L)
library(anotherSAS7bdat, lib.loc = normalizePath(args[2L]))
stopifnot(requireNamespace("arrow", quietly = TRUE))
path <- normalizePath(args[1L], winslash = "/", mustWork = TRUE)
iterations <- if (length(args) >= 3L) as.integer(args[3L]) else 7L
stopifnot(iterations >= 1L)
directory <- tempfile("direct-parquet-benchmark-", tmpdir = normalizePath(".work"))
dir.create(directory)

through_r <- function(output) {
  sink <- arrow::FileOutputStream$create(output)
  writer <- NULL
  on.exit({
    if (!is.null(writer)) try(writer$Close(), silent = TRUE)
    sink$close()
  })
  result <- sas7bdat_read(path, chunk_rows = 100000L, callback = function(chunk) {
    # Match the direct function's lossless double-second storage for SAS times.
    for (name in names(chunk)) {
      if (inherits(chunk[[name]], "hms")) {
        attributes(chunk[[name]])[c("class", "units")] <- NULL
      }
    }
    batch <- arrow::RecordBatch$create(chunk)
    if (is.null(writer)) {
      writer <<- arrow::ParquetFileWriter$create(
        batch$schema, sink,
        properties = arrow::ParquetWriterProperties$create(
          names(chunk), version = "2.6", compression = "snappy"
        )
      )
    }
    writer$WriteBatch(batch, chunk_size = 100000L)
  })
  writer$Close()
  writer <- NULL
  invisible(result)
}
engines <- list(
  through_R = through_r,
  direct = function(output) sas7bdat_to_parquet(path, output, missing_tags = FALSE),
  direct_with_tags = function(output) sas7bdat_to_parquet(path, output)
)
output_path <- function(engine) file.path(directory, paste0(engine, ".parquet"))
run <- function(engine, remove = TRUE) {
  output <- output_path(engine)
  result <- engines[[engine]](output)
  stopifnot(result$completed)
  if (remove) unlink(output)
  invisible(result)
}

# Warm each engine and validate every output value across the entire input.
summaries <- lapply(names(engines), function(engine) run(engine, remove = FALSE))
stopifnot(length(unique(vapply(summaries, `[[`, numeric(1), "rows"))) == 1L)
expected <- arrow::read_parquet(output_path("through_R"))
for (engine in c("direct", "direct_with_tags")) {
  actual <- arrow::read_parquet(output_path(engine))
  stopifnot(identical(names(actual)[seq_along(expected)], names(expected)))
  for (name in names(expected)) {
    x <- expected[[name]]
    y <- actual[[name]]
    stopifnot(identical(class(x), class(y)), identical(is.na(x), is.na(y)))
    if (is.character(x)) stopifnot(identical(as.character(x), as.character(y)))
    else stopifnot(isTRUE(all.equal(as.numeric(x), as.numeric(y), tolerance = 1e-6)))
  }
}
unlink(vapply(names(engines), output_path, character(1)))
rm(expected, actual, x, y)
elapsed <- setNames(lapply(engines, function(x) numeric(iterations)), names(engines))
for (iteration in seq_len(iterations)) {
  order <- if (iteration %% 2L) names(engines) else rev(names(engines))
  for (engine in order) {
    invisible(gc())
    elapsed[[engine]][iteration] <- system.time(run(engine))[["elapsed"]]
    cat(sprintf("%s iteration=%d seconds=%.3f\n", engine, iteration, elapsed[[engine]][iteration]))
  }
}
allocations <- vapply(names(engines), function(engine) {
  profile <- tempfile(tmpdir = directory)
  invisible(gc())
  Rprofmem(profile)
  run(engine)
  Rprofmem(NULL)
  lines <- readLines(profile)
  unlink(profile)
  sum(as.double(sub(" .*", "", lines[grepl("^[0-9]+", lines)])))
}, numeric(1))
results <- data.frame(
  engine = names(engines), rows = summaries[[1L]]$rows,
  median_seconds = vapply(elapsed, median, numeric(1)),
  min_seconds = vapply(elapsed, min, numeric(1)),
  max_seconds = vapply(elapsed, max, numeric(1)),
  R_allocated_bytes = allocations
)
write.csv(results, ".work/direct-parquet-benchmark.csv", row.names = FALSE)
write.csv(data.frame(iteration = seq_len(iterations), as.data.frame(elapsed)),
          ".work/direct-parquet-benchmark-samples.csv", row.names = FALSE)
unlink(directory)
print(results, row.names = FALSE)
