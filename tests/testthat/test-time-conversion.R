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

# The former R conversion is retained here as an independent regression oracle.
adjust_in_r <- function(x, kind) {
  if (kind %in% c("date", "datetime")) {
    valid <- !is.na(x)
    x[valid] <- x[valid] - if (kind == "date") 3653 else 3653 * 86400
  }
  if (kind == "date") class(x) <- "Date"
  if (kind == "datetime") {
    class(x) <- c("POSIXct", "POSIXt")
    attr(x, "tzone") <- "UTC"
  }
  if (kind == "time") {
    out <- hms::new_hms(as.numeric(x))
    attr(out, "format.sas") <- attr(x, "format.sas", exact = TRUE)
    attr(out, "label") <- attr(x, "label", exact = TRUE)
    x <- out
  }
  x
}

test_that("native conversion matches R adjustment across slices and missing tags", {
  skip_if_not_installed("haven")
  # SAS's writer expects uppercase tags; the reader normalizes them for haven.
  tags <- vapply(c(LETTERS, "_"), function(tag) {
    bytes <- writeBin(NA_real_, raw(), size = 8L, endian = "little")
    bytes[5L] <- charToRaw(tag)
    readBin(bytes, "double", n = 1L, size = 8L, endian = "little")
  }, numeric(1))
  values <- rep(c(-4000, -0.125, 0, 3653, 90061.25, NA_real_, tags),
                length.out = 33013L)
  input <- data.frame(date = values, datetime = values * 86400,
                      time = values, number = values, custom = values,
                      text = rep("1960-01-01", length(values)))
  # Restore tag bits after arithmetic in the fixture's datetime column.
  input$datetime[is.na(values)] <- values[is.na(values)]
  formats <- c("DATE9.", "DATETIME26.6", "TIME12.3", "BEST12.", "CUSTOM_DATE.")
  kinds <- c("date", "datetime", "time", "numeric", "numeric", "numeric")
  for (i in seq_along(formats)) {
    attr(input[[i]], "format.sas") <- formats[i]
    attr(input[[i]], "label") <- paste("Label", names(input)[i])
  }
  attr(input$text, "format.sas") <- "DATE9."
  path <- tempfile(fileext = ".sas7bdat")
  on.exit(unlink(path))
  suppressWarnings(haven::write_sas(input, path))
  raw_reader <- sas7bdat_open(path, dates = FALSE)
  reader <- sas7bdat_open(path)
  on.exit(sas7bdat_close(raw_reader), add = TRUE)
  on.exit(sas7bdat_close(reader), add = TRUE)
  # Changing requests forces slices of existing batches and merging batches.
  for (n in c(1L, 3L, 33000L, 9L)) {
    raw <- sas7bdat_read_chunk(raw_reader, n)
    converted <- sas7bdat_read_chunk(reader, n)
    expected <- raw
    for (i in seq_along(expected)) expected[[i]] <- adjust_in_r(raw[[i]], kinds[i])
    expect_identical(converted, expected)
    for (i in 1:3) {
      expect_identical(haven::na_tag(converted[[i]]), haven::na_tag(raw[[i]]))
      missing <- is.na(raw[[i]])
      expect_identical(writeBin(as.numeric(converted[[i]])[missing], raw(), size = 8L),
                       writeBin(as.numeric(raw[[i]])[missing], raw(), size = 8L))
    }
  }
  expect_null(sas7bdat_read_chunk(reader))
  expect_null(sas7bdat_read_chunk(raw_reader))
})

test_that("formats are classified once and conversion follows the reader flag", {
  skip_if_not_installed("haven")
  formats <- c("date9.", "YYMMDD10.", "IS8601DA10.", "E8601DA10.", "NENGO.",
               "DATETIME26.6", "DATEAMPM.", "DTDATE9.", "NLDATM.", "IS8601DZ.",
               "B8601DX.", "E8601LX.", "time12.3", "HHMM.", "IS8601TM.",
               "E8601LZ.", "NLTIM.", "BEST12.", "CUSTOM_DATE.")
  kinds <- c(rep("date", 5L), rep("datetime", 7L), rep("time", 5L),
             rep("numeric", 2L))
  values <- c(-1.5, 0, 3653, 90061.25, NA_real_)
  input <- as.data.frame(setNames(rep(list(values), length(formats)),
                                 paste0("column", seq_along(formats))))
  for (i in seq_along(formats)) attr(input[[i]], "format.sas") <- formats[i]
  path <- tempfile(fileext = ".sas7bdat")
  on.exit(unlink(path))
  suppressWarnings(haven::write_sas(input, path))
  original <- anotherSAS7bdat:::sas_date_kind
  calls <- character()
  local_mocked_bindings(sas_date_kind = function(fmt) {
    calls <<- c(calls, fmt)
    original(fmt)
  }, .package = "anotherSAS7bdat")
  reader <- sas7bdat_open(path, chunk_rows = 2L, dates = FALSE)
  on.exit(sas7bdat_close(reader), add = TRUE)
  expect_length(calls, length(formats))
  classified <- calls
  raw <- sas7bdat_read_chunk(reader)
  expect_false(any(vapply(raw, is.object, logical(1))))
  reader$dates <- TRUE
  converted <- sas7bdat_read_chunk(reader)
  reader$dates <- FALSE
  last <- sas7bdat_read_chunk(reader)
  expect_false(any(vapply(last, is.object, logical(1))))
  expect_identical(calls, classified)
  for (i in seq_along(formats)) {
    expected <- values[3:4]
    attr(expected, "format.sas") <- attr(raw[[i]], "format.sas")
    expect_identical(converted[[i]], adjust_in_r(expected, kinds[i]))
  }
})
