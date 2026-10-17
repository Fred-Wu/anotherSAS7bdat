# Run from repository root, with patched Arrow R installed:
# Rscript tools/benchmark-threaded-parquet.R input.sas7bdat output_dir [chunk_rows] [iterations]
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L) stop("Expected input SAS path and existing output directory.")
stopifnot(requireNamespace("anotherSAS7bdat", quietly = TRUE),
          requireNamespace("arrow", quietly = TRUE))
path <- normalizePath(args[1L], mustWork = TRUE)
directory <- normalizePath(args[2L], mustWork = TRUE)
chunk_rows <- if (length(args) >= 3L) as.integer(args[3L]) else 100000L
iterations <- if (length(args) >= 4L) as.integer(args[4L]) else 3L
stopifnot(chunk_rows > 0L, iterations > 0L)
props <- get("ParquetArrowWriterProperties", asNamespace("arrow"))
if (!("use_threads" %in% names(formals(props$create))) ||
    !all(c("NewBufferedRowGroup", "WriteRecordBatch") %in%
         names(arrow::ParquetFileWriter$public_methods))) {
  stop("Install the patched Arrow R bindings first; see tools/README-threaded-parquet.md.")
}
modes <- list(baseline = NULL, buffered1 = 1L, buffered2 = 2L,
              buffered4 = 4L, buffered8 = 8L)
readr <- anotherSAS7bdat::sas7bdat_open(path)
metadata <- anotherSAS7bdat::sas7bdat_info(readr)
anotherSAS7bdat::sas7bdat_close(readr)
cat("Input columns:", nrow(metadata$columns), "rows:", metadata$rows_total, "\n")
results <- vector("list", iterations * length(modes))
k <- 0L
for (iteration in seq_len(iterations)) {
  order <- if (iteration %% 2L == 1L) names(modes) else rev(names(modes))
  for (mode in order) {
    invisible(gc())
    output <- tempfile(paste0("threaded-", mode, "-"), tmpdir = directory, fileext = ".parquet")
    elapsed <- system.time({
      result <- anotherSAS7bdat::sas7bdat_to_parquet(
        path, output, chunk_rows = chunk_rows,
        writer_threads = modes[[mode]], progress = FALSE)
    })[["elapsed"]]
    size <- file.info(output)$size
    groups <- arrow::ParquetFileReader$create(output)$num_row_groups
    stopifnot(isTRUE(result$completed), result$rows == metadata$rows_total)
    unlink(output)
    k <- k + 1L
    results[[k]] <- data.frame(
      iteration = iteration, mode = mode, columns = nrow(metadata$columns),
      rows = result$rows, chunks = result$chunks, row_groups = groups,
      seconds = elapsed, million_rows_per_sec = result$rows / elapsed / 1e6,
      parquet_MB = size / 1e6)
    cat(sprintf("iter=%d mode=%s elapsed=%.3fs size=%.1fMB groups=%d\n",
                iteration, mode, elapsed, size / 1e6, groups))
  }
}
results <- do.call(rbind, results)
write.csv(results, file.path(directory, "threaded-parquet-benchmark.csv"), row.names = FALSE)
print(aggregate(seconds ~ mode, results, median), row.names = FALSE)
