test_that("writer_threads rejects invalid values", {
  skip_if_not_installed("arrow", "14.0.0")
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output))
  for (n in list(0L, -2L, 1.5, Inf, NA_integer_, TRUE, "4")) {
    expect_error(sas7bdat_to_parquet(example_path("rle"), output,
                                    writer_threads = n),
                 "positive integer")
  }
})

test_that("threaded writer requires patched Arrow R bindings", {
  skip_if_not_installed("arrow", "14.0.0")
  props <- get("ParquetArrowWriterProperties", asNamespace("arrow"))
  patched <- "use_threads" %in% names(formals(props$create)) &&
    all(c("NewBufferedRowGroup", "WriteRecordBatch") %in%
          names(arrow::ParquetFileWriter$public_methods))
  if (patched) skip("Patched Arrow R is installed")
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output))
  expect_error(sas7bdat_to_parquet(example_path("rle"), output,
                                  writer_threads = 4L),
               "requires the experimental Arrow R buffered writer bindings")
  expect_false(file.exists(output))
})

test_that("buffered writer matches original with all SAS compression types", {
  skip_if_not_installed("arrow", "14.0.0")
  props <- get("ParquetArrowWriterProperties", asNamespace("arrow"))
  patched <- "use_threads" %in% names(formals(props$create)) &&
    all(c("NewBufferedRowGroup", "WriteRecordBatch") %in%
          names(arrow::ParquetFileWriter$public_methods))
  if (!patched) skip("Requires the experimental Arrow R buffered writer bindings")

  original_cpu_count <- arrow::cpu_count()
  for (compression in c("uncompressed", "rle", "rdc")) {
    path <- example_path(compression)
    outputs <- lapply(seq_len(3L), function(i) tempfile(fileext = ".parquet"))
    on.exit(unlink(unlist(outputs)), add = TRUE)
    sas7bdat_to_parquet(path, outputs[[1L]], chunk_rows = 17L, missing_tags = TRUE,
                        progress = FALSE)
    sas7bdat_to_parquet(path, outputs[[2L]], chunk_rows = 17L, missing_tags = TRUE,
                        writer_threads = 1L, progress = FALSE)
    sas7bdat_to_parquet(path, outputs[[3L]], chunk_rows = 17L, missing_tags = TRUE,
                        writer_threads = 4L, progress = FALSE)
    expected <- arrow::read_parquet(outputs[[1L]], as_data_frame = FALSE)
    for (output in outputs[-1L]) {
      actual <- arrow::read_parquet(output, as_data_frame = FALSE)
      expect_equal(as.data.frame(actual), as.data.frame(expected))
      expect_identical(actual$schema$metadata, expected$schema$metadata)
      expect_identical(actual$schema$names, expected$schema$names)
      expect_equal(arrow::ParquetFileReader$create(output)$num_row_groups, 8L)
    }
    expect_identical(arrow::cpu_count(), original_cpu_count)
    unlink(unlist(outputs))
  }
})

test_that("buffered writer supports empty SAS files", {
  skip_if_not_installed("arrow", "14.0.0")
  skip_if_not_installed("haven")
  props <- get("ParquetArrowWriterProperties", asNamespace("arrow"))
  if (!("use_threads" %in% names(formals(props$create)))) {
    skip("Requires patched Arrow R bindings")
  }
  path <- tempfile(fileext = ".sas7bdat")
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(c(path, output)))
  suppressWarnings(haven::write_sas(data.frame(id = double(), text = character()), path))
  summary <- sas7bdat_to_parquet(path, output, writer_threads = 2L, progress = FALSE)
  expect_equal(summary$rows, 0)
  expect_equal(nrow(arrow::read_parquet(output)), 0)
})
