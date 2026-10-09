test_that("native Parquet conversion matches all three SAS compression types", {
  skip_if_not_installed("arrow", "14.0.0")
  for (compression in c("uncompressed", "rle", "rdc")) {
    path <- example_path(compression)
    output <- tempfile(fileext = ".parquet")
    on.exit(unlink(output), add = TRUE)
    collected <- collect_chunks(path)
    expected <- collected$data
    result <- sas7bdat_to_parquet(path, output, chunk_rows = 17L)
    table <- arrow::read_parquet(output, as_data_frame = FALSE)
    actual <- as.data.frame(table)
    expect_equal(result$rows, 120)
    expect_equal(result$chunks, 8)
    expect_true(result$completed)
    expect_equal(plain_values(actual[names(expected)]), plain_values(expected), tolerance = 1e-6)
    expect_identical(class(actual$visit_date), "Date")
    expect_s3_class(actual$recorded_at, "POSIXct")
    expect_identical(attr(actual$recorded_at, "tzone"), "UTC")
    for (name in names(expected)) {
      field <- table$schema$GetFieldByName(name)
      metadata <- collected$info$columns[match(name, collected$info$columns$name), ]
      expect_identical(field$metadata[["sas.label"]], metadata$label)
      expect_identical(field$metadata[["sas.format"]], metadata$format)
    }
    parquet <- arrow::ParquetFileReader$create(output)
    expect_equal(parquet$num_row_groups, 8)
  }
})

test_that("direct conversion never constructs R dataset columns", {
  skip_if_not_installed("arrow", "14.0.0")
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output))
  local_mocked_bindings(
    sas7bdat_read_chunk = function(...) stop("R data frame conversion was called"),
    native_next = function(...) stop("R column construction was called"),
    .package = "anotherSAS7bdat"
  )
  result <- sas7bdat_to_parquet(example_path("rle"), output,
                               chunk_rows = 19L, chunk_bytes = 1,
                               columns = c("text", "id"), missing_tags = FALSE)
  expect_equal(result$rows, 120)
  expect_equal(result$chunks, 120)
  expect_identical(names(arrow::read_parquet(output)), c("text", "id"))
  expect_length(result$missing_tag_columns, 0)
})

test_that("special missing tags and temporal edge cases are preserved explicitly", {
  skip_if_not_installed("arrow", "14.0.0")
  skip_if_not_installed("haven")
  sas_tags <- vapply(c(LETTERS, "_"), function(tag) {
    bytes <- writeBin(NA_real_, raw(), size = 8L, endian = "little")
    bytes[5L] <- charToRaw(tag)
    readBin(bytes, "double", n = 1L, size = 8L, endian = "little")
  }, numeric(1))
  values <- c(0, -1.5, 90061.25, 0.125, NA_real_, sas_tags)
  input <- data.frame(time = values, number = values,
                      number__sas_missing = rep("existing", length(values)),
                      text = rep(c("caf\u00e9", "\u4e2d\u6587", "", "longer text"), 8L))
  attr(input$time, "format.sas") <- "TIME12.3"
  attr(input$time, "label") <- "Extended hours"
  path <- tempfile(fileext = ".sas7bdat")
  output <- paste0(tempfile(), "-\u6d4b\u8bd5.parquet")
  on.exit(unlink(c(path, output)))
  suppressWarnings(haven::write_sas(input, path))
  result <- sas7bdat_to_parquet(path, output, chunk_rows = 3L)
  data <- arrow::read_parquet(output)
  raw <- collect_chunks(path, dates = FALSE)$data
  expect_equal(data$time, raw$time, ignore_attr = TRUE)
  expect_identical(is.na(data$number), is.na(raw$number))
  expect_identical(data$text, raw$text)
  expect_identical(data$number__sas_missing, rep("existing", length(values)))
  expect_identical(unname(result$missing_tag_columns["number"]), "number__sas_missing.1")
  for (name in c("time", "number")) {
    expect_identical(data[[result$missing_tag_columns[[name]]]], haven::na_tag(raw[[name]]))
  }
})

test_that("date precision checks leave no incomplete published output", {
  skip_if_not_installed("arrow", "14.0.0")
  skip_if_not_installed("haven")
  input <- data.frame(day = c(3653, 3653.125), instant = c(0.125, 0.000000125))
  attr(input$day, "format.sas") <- "DATE9."
  attr(input$instant, "format.sas") <- "DATETIME26.6"
  path <- tempfile(fileext = ".sas7bdat")
  directory <- tempfile()
  dir.create(directory)
  output <- file.path(directory, "data.parquet")
  on.exit(unlink(c(path, directory), recursive = TRUE))
  suppressWarnings(haven::write_sas(input, path))
  expect_error(sas7bdat_to_parquet(path, output, chunk_rows = 1L), "dates = FALSE")
  expect_false(file.exists(output))
  expect_length(list.files(directory, all.files = TRUE, no.. = TRUE), 0)
  sas7bdat_to_parquet(path, output, dates = FALSE, missing_tags = FALSE)
  expect_identical(plain_values(arrow::read_parquet(output)), plain_values(input))
  before <- readBin(output, "raw", n = file.info(output)$size)
  expect_error(sas7bdat_to_parquet(path, output), "already exists")
  expect_identical(readBin(output, "raw", n = file.info(output)$size), before)
})

test_that("schema-only files and native exports survive cleanup", {
  skip_if_not_installed("arrow", "14.0.0")
  skip_if_not_installed("haven")
  path <- tempfile(fileext = ".sas7bdat")
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(c(path, output)))
  suppressWarnings(haven::write_sas(data.frame(id = numeric(), text = character()), path))
  result <- sas7bdat_to_parquet(path, output)
  expect_equal(result$rows, 0)
  expect_equal(result$chunks, 0)
  expect_identical(names(arrow::read_parquet(output)), c("id", "text", "id__sas_missing"))

  reader <- sas7bdat_open(example_path("uncompressed"))
  on.exit(sas7bdat_close(reader), add = TRUE)
  tags <- rep("", nrow(sas7bdat_info(reader)$columns))
  exported <- anotherSAS7bdat:::native_arrow_next(reader$ptr, 13L, TRUE, tags)
  batch <- arrow::RecordBatch$import_from_c(exported$array, exported$schema)
  first <- as.data.frame(batch)
  # The imported buffers own their data, independent of recycling/reader close.
  invisible(anotherSAS7bdat:::native_arrow_next(reader$ptr, 17L, TRUE, tags))
  sas7bdat_close(reader)
  gc()
  expect_identical(as.data.frame(batch), first)
})

test_that("writer and decoder errors clean up temporary Parquet files", {
  skip_if_not_installed("arrow", "14.0.0")
  directory <- tempfile()
  dir.create(directory)
  on.exit(unlink(directory, recursive = TRUE))
  output <- file.path(directory, "out.parquet")
  expect_error(sas7bdat_to_parquet(example_path("rdc"), output,
                                  compression = "not_a_codec"))
  expect_length(list.files(directory, all.files = TRUE, no.. = TRUE), 0)
  native_next_batch <- anotherSAS7bdat:::native_arrow_next
  calls <- 0L
  local_mocked_bindings(native_arrow_next = function(...) {
    calls <<- calls + 1L
    if (calls == 2L) stop("decoder failed")
    native_next_batch(...)
  }, .package = "anotherSAS7bdat")
  expect_error(sas7bdat_to_parquet(example_path("rdc"), output, chunk_rows = 17L), "decoder failed")
  expect_equal(calls, 2L)
  expect_length(list.files(directory, all.files = TRUE, no.. = TRUE), 0)
})

test_that("a writer failure does not publish a partial file", {
  skip_if_not_installed("arrow", "14.0.0")
  directory <- tempfile()
  dir.create(directory)
  on.exit(unlink(directory, recursive = TRUE))
  output <- file.path(directory, "out.parquet")
  native_next_batch <- anotherSAS7bdat:::native_arrow_next
  # Deliberately supply a valid batch with raw-double dates to a typed-date
  # writer: Arrow must reject the schema mismatch during the actual write.
  local_mocked_bindings(native_arrow_next = function(ptr, n, dates, tags) {
    native_next_batch(ptr, n, FALSE, tags)
  }, .package = "anotherSAS7bdat")
  expect_error(sas7bdat_to_parquet(example_path("rle"), output), "[Ss]chema")
  expect_length(list.files(directory, all.files = TRUE, no.. = TRUE), 0)
})
