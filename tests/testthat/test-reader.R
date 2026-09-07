test_that("readable byte targets have explicit binary and decimal units", {
  expect_equal(AnotherSAS7bdat:::byte_limit("128 MiB"), 128 * 1024^2)
  expect_equal(AnotherSAS7bdat:::byte_limit("128 MB"), 128 * 1000^2)
  expect_equal(AnotherSAS7bdat:::byte_limit(" 1.5 mib "), 1.5 * 1024^2)
  expect_equal(AnotherSAS7bdat:::byte_limit(".5 KiB"), 512)
  expect_equal(AnotherSAS7bdat:::byte_limit("1GB"), 1000^3)
  expect_equal(AnotherSAS7bdat:::byte_limit("1 GiB"), 1024^3)
  expect_equal(AnotherSAS7bdat:::byte_limit(134217728), 128 * 1024^2)
  for (x in list("128", "0 MiB", "-1 MiB", "one MB", "Inf MB", "1 megabyte",
                 "1e300 GB", "0.1 B", NA_character_, c("1 MB", "2 MB"),
                 list("1 MB"), "9007199254740992 B")) {
    expect_error(AnotherSAS7bdat:::byte_limit(x), "chunk_bytes")
  }
})

test_that("many pages, tagged missings, UTF-8 paths and labels survive chunking", {
  skip_if_not_installed("haven")
  path <- paste0(tempfile(), "-\u6d4b\u8bd5.sas7bdat")
  # SAS's writer accepts uppercase tags, whereas haven::tagged_na() lowercases
  # them. Construct the documented tagged-NA payload for this generated file.
  sas_tag <- function(tag) {
    bytes <- writeBin(NA_real_, raw(), size = 8L, endian = "little")
    bytes[5L] <- charToRaw(tag)
    readBin(bytes, "double", n = 1L, size = 8L, endian = "little")
  }
  input <- data.frame(id = as.double(1:5000),
    text = rep(c("caf\u00e9", "\u4e2d\u6587", "", "hello"), 1250),
    value = rep(c(NA_real_, sas_tag("A"), sas_tag("Z"), 3.5), 1250),
    day = as.Date("2020-01-01") + 0:4999,
    instant = as.POSIXct("2020-01-01", tz = "UTC") + 0:4999)
  attr(input$id, "label") <- "Observation identifier"
  source <- tempfile(fileext = ".sas7bdat")
  suppressWarnings(haven::write_sas(input, source))
  expect_true(file.copy(source, path))
  result <- collect_chunks(path, chunk_rows = 127L)
  actual <- result$data
  expected <- haven::read_sas(source)
  expect_equal(plain_values(actual), plain_values(expected))
  expect_identical(haven::na_tag(actual$value), haven::na_tag(expected$value))
  expect_equal(attr(actual$id, "label"), "Observation identifier")
  expect_identical(as.numeric(actual$id), as.numeric(expected$id))
  expect_equal(result$info$file_opens, 1)
  expect_equal(result$info$file_closes, 1)
  expect_equal(result$info$rows_decoded, nrow(input))
})
