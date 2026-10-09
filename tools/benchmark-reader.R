# Run in separate R processes for the baseline and changed package libraries:
# Rscript tools/benchmark-reader.R generate .work/benchmark.sas7bdat
# Rscript tools/benchmark-reader.R .work/baseline-lib .work/benchmark.sas7bdat read
# Rscript tools/benchmark-reader.R .work/new-lib .work/benchmark.sas7bdat parquet
# Optional trailing arguments: iterations (default 3), chunk_rows (default 10000).
# Parquet mode writes one temporary Snappy file per chunk, on the same disk as
# the input. Timings include R construction, processing, and reader cleanup.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L) stop("Supply a library directory and SAS file, or generate and a SAS file.")
path <- args[2L]
if (args[1L] == "generate") {
  stopifnot(requireNamespace("haven", quietly = TRUE))
  n <- 500000L
  input <- as.data.frame(setNames(lapply(1:12, function(j) as.double(seq_len(n)) / j),
                                 paste0("number", 1:12)))
  for (j in 1:4) {
    input[[paste0("text", j)]] <- sprintf("%08d-%d-%s", seq_len(n), j,
                                        strrep("caf\u00e9-", 12))
  }
  haven::write_sas(input, path)
  cat("Generated", n, "rows in", path, "\n")
  quit(status = 0L)
}
library(anotherSAS7bdat, lib.loc = normalizePath(args[1L]))
mode <- if (length(args) >= 3L) args[3L] else "read"
stopifnot(mode %in% c("read", "parquet"))
if (mode == "parquet") stopifnot(requireNamespace("arrow", quietly = TRUE))
iterations <- if (length(args) >= 4L) as.integer(args[4L]) else 3L
chunk_rows <- if (length(args) >= 5L) as.integer(args[5L]) else 10000L
output <- tempfile("reader-benchmark-", tmpdir = dirname(path))
dir.create(output)
elapsed <- numeric(iterations)
for (iteration in seq_len(iterations)) {
  gc()
  elapsed[iteration] <- system.time({
    part <- 0L
    summary <- sas7bdat_read(path, chunk_rows = chunk_rows, dates = FALSE,
                            callback = function(chunk) {
      if (mode == "parquet") {
        part <<- part + 1L
        arrow::write_parquet(chunk, file.path(output, paste0(part, ".parquet")),
                             compression = "snappy")
      }
    })
  })[["elapsed"]]
  cat(sprintf("iteration=%d mode=%s rows=%.0f chunks=%.0f seconds=%.3f\n",
              iteration, mode, summary$rows, summary$chunks, elapsed[iteration]))
  unlink(list.files(output, full.names = TRUE))
}
unlink(output, recursive = TRUE)
cat(sprintf("median_seconds=%.3f\n", median(elapsed)))
