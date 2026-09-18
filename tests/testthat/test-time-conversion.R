test_that("SAS times display as HH:MM:SS across chunks and compression types", {
  for (compression in c("uncompressed", "rle", "rdc")) {
    path <- system.file("examples", paste0("example_", compression, ".sas7bdat"),
                        package = "anotherSAS7bdat")
    result <- collect_chunks(path, chunk_rows = 17L)
    raw <- collect_chunks(path, chunk_rows = 17L, dates = FALSE)$data

    for (chunk in result$chunks) {
      expect_s3_class(chunk$visit_time, "hms")
      expect_s3_class(chunk$visit_time, "difftime")
      expect_identical(attr(chunk$visit_time, "label"), "Visit time")
      expect_identical(attr(chunk$visit_time, "format.sas"),
                       attr(raw$visit_time, "format.sas"))
    }
    time <- result$data$visit_time
    expect_s3_class(time, "hms")
    expect_identical(as.numeric(time), as.numeric(raw$visit_time))
    expect_identical(format(time[1:2]), c("09:00:30", "09:01:00"))
    expect_match(paste(capture.output(print(result$data[1:2, ])), collapse = "\n"),
                 "09:00:30")
    expect_true(is.na(time[50]))
    expect_false(is.object(raw$visit_time))
    expect_s3_class(result$data$visit_date, "Date")
    expect_s3_class(result$data$recorded_at, "POSIXct")
    expect_identical(attr(result$data$recorded_at, "tzone"), "UTC")
  }
})

test_that("time conversion preserves fractions, extended hours and tagged NAs", {
  skip_if_not_installed("haven")
  # The SAS writer needs an uppercase tag in the NA payload.
  bytes <- writeBin(NA_real_, raw(), size = 8L, endian = "little")
  bytes[5L] <- charToRaw("A")
  tagged <- readBin(bytes, "double", n = 1L, size = 8L, endian = "little")
  values <- c(0, 1, 86399, 0.125, -1.5, 90061.25, NA_real_, tagged)
  input <- data.frame(time = values)
  attr(input$time, "format.sas") <- "TIME12.3"
  attr(input$time, "label") <- "Time with fractional seconds"
  path <- tempfile(fileext = ".sas7bdat")
  on.exit(unlink(path))
  suppressWarnings(haven::write_sas(input, path))
  raw <- collect_chunks(path, dates = FALSE)$data$time
  chunks <- list()
  sas7bdat_read(path, chunk_rows = 3L, callback = function(chunk) {
    chunks[[length(chunks) + 1L]] <<- chunk
  })
  time <- do.call(rbind, chunks)$time

  expect_s3_class(time, "hms")
  expect_identical(as.numeric(time), as.numeric(raw))
  expect_identical(as.character(time[1:3]),
                   c("00:00:00", "00:00:01", "23:59:59"))
  expect_identical(as.character(time[4:6]),
                   c("00:00:00.125", "-00:00:01.500", "25:01:01.250"))
  expect_identical(is.na(time), is.na(raw))
  expect_identical(haven::na_tag(time), haven::na_tag(raw))
  expect_true(haven::is_tagged_na(time[8]))
  expect_identical(writeBin(as.numeric(time), raw(), size = 8L),
                   writeBin(as.numeric(raw), raw(), size = 8L))
  expect_identical(attr(chunks[[1]]$time, "label"), attr(raw, "label"))
  expect_identical(attr(chunks[[1]]$time, "format.sas"), attr(raw, "format.sas"))
})
