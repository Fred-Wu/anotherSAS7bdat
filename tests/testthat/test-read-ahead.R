test_that("read-ahead progresses during processing and stops at its bound", {
  for (compression in c("uncompressed", "rle", "rdc")) {
    reader <- sas7bdat_open(example_path(compression), chunk_rows = 7L)
    expect_equal(sas7bdat_info(reader)$rows_decoded, 0)
    first <- sas7bdat_read_chunk(reader)
    saved <- serialize(first, NULL)
    info <- wait_for_decoded(reader, 21)
    expect_equal(info$rows_delivered, 7)
    expect_equal(info$rows_decoded, 21) # Delivered + queued + in progress.
    Sys.sleep(0.05)
    expect_equal(sas7bdat_info(reader)$rows_decoded, 21)
    for (i in 1:4) sas7bdat_read_chunk(reader)
    sas7bdat_close(reader) # Also releases a worker blocked by a full queue.
    sas7bdat_close(reader)
    expect_identical(serialize(first, NULL), saved)
    info <- sas7bdat_info(reader)
    expect_identical(info$status, "closed")
    expect_equal(info$file_opens, 1)
    expect_equal(info$file_closes, 1)
    expect_error(sas7bdat_read_chunk(reader), "closed")
  }
})

test_that("changing n splits and combines prefetched data without losing rows", {
  for (compression in c("uncompressed", "rle", "rdc")) {
    path <- example_path(compression)
    expected <- collect_chunks(path, chunk_rows = 120L, dates = FALSE)$data
    reader <- sas7bdat_open(path, chunk_rows = 31L, dates = FALSE,
                           columns = rev(names(expected)))
    out <- list()
    rows <- 0L
    for (n in c(31L, 1L, 3L, 40L, 2L, 17L, 100L)) {
      chunk <- sas7bdat_read_chunk(reader, n)
      expect_equal(nrow(chunk), min(n, 120L - rows))
      expect_identical(names(chunk), rev(names(expected)))
      out[[length(out) + 1L]] <- chunk
      rows <- rows + nrow(chunk)
      if (length(out) == 1L) wait_for_decoded(reader, 93)
    }
    expect_null(sas7bdat_read_chunk(reader))
    expect_equal(plain_values(do.call(rbind, out)), plain_values(expected[rev(names(expected))]))
    expect_equal(sas7bdat_info(reader)$rows_delivered, 120)
    expect_identical(sas7bdat_info(reader)$status, "eof")
    sas7bdat_close(reader)
  }
})

test_that("byte limits retain row boundaries when n changes", {
  skip_if_not_installed("haven")
  path <- tempfile(fileext = ".sas7bdat")
  on.exit(unlink(path))
  input <- data.frame(id = as.double(1:200), value = rep(c(NA_real_, 3.5), 100))
  suppressWarnings(haven::write_sas(input, path))
  # Per-row accounting matches the documented approximate decoded target.
  size <- rep(18, nrow(input))
  reader <- sas7bdat_open(path, chunk_rows = 19L, chunk_bytes = 60, dates = FALSE)
  on.exit(sas7bdat_close(reader), add = TRUE)
  start <- 1L
  for (n in rep(c(19L, 1L, 30L, 2L), 100)) {
    if (start > nrow(input)) break
    end <- min(nrow(input), start + n - 1L)
    hit <- which(cumsum(size[start:end]) >= 60)[1L]
    if (!is.na(hit)) end <- start + hit - 1L
    chunk <- sas7bdat_read_chunk(reader, n)
    expect_equal(plain_values(chunk), plain_values(input[start:end, , drop = FALSE]))
    start <- end + 1L
  }
  expect_null(sas7bdat_read_chunk(reader))
  sas7bdat_close(reader)
  # Even an oversized character row is returned whole, in a one-row chunk.
  example <- example_path("rle")
  reader <- sas7bdat_open(example, chunk_rows = 19L, chunk_bytes = 1, dates = FALSE)
  expected <- collect_chunks(example, chunk_rows = 120L, dates = FALSE)$data
  chunks <- lapply(1:120, function(i) sas7bdat_read_chunk(reader, if (i %% 2) 1L else 30L))
  expect_true(all(vapply(chunks, nrow, integer(1)) == 1L))
  expect_equal(plain_values(do.call(rbind, chunks)), plain_values(expected))
  expect_null(sas7bdat_read_chunk(reader))
})

test_that("empty files and callback exits clean up the native worker", {
  skip_if_not_installed("haven")
  path <- tempfile(fileext = ".sas7bdat")
  on.exit(unlink(path))
  suppressWarnings(haven::write_sas(data.frame(id = double(), text = character()), path))
  reader <- sas7bdat_open(path)
  expect_null(sas7bdat_read_chunk(reader))
  expect_identical(sas7bdat_info(reader)$status, "eof")
  sas7bdat_close(reader)
  expect_equal(sas7bdat_info(reader)$file_closes, 1)

  retained <- NULL
  closed <- NULL
  original_close <- anotherSAS7bdat:::native_close
  testthat::local_mocked_bindings(native_close = function(ptr) {
    original_close(ptr)
    closed <<- anotherSAS7bdat:::native_info(ptr)
  }, .package = "anotherSAS7bdat")
  summary <- sas7bdat_read(example_path("rle"), chunk_rows = 7L,
                         callback = function(chunk) { retained <<- chunk; FALSE })
  expect_equal(summary, list(rows = 7, chunks = 1, completed = FALSE))
  expect_equal(nrow(retained), 7)
  expect_identical(closed$status, "closed")
  expect_equal(closed$file_closes, 1)
  closed <- NULL
  expect_error(sas7bdat_read(example_path("rdc"), chunk_rows = 7L,
                           callback = function(chunk) stop("callback failed")), "callback failed")
  expect_identical(closed$status, "closed")
  expect_equal(closed$file_closes, 1)
  # A new reader still starts from the beginning after either exit.
  expect_equal(nrow(collect_chunks(example_path("rdc"))$data), 120)
})

test_that("a later I/O error drains completed batches and closes the file", {
  skip_if_not_installed("haven")
  path <- tempfile(fileext = ".sas7bdat")
  on.exit(unlink(path))
  suppressWarnings(haven::write_sas(data.frame(id = as.double(1:10000),
    text = rep(strrep("x", 200), 10000)), path))
  reader <- sas7bdat_open(path, chunk_rows = 100L, dates = FALSE)
  on.exit(sas7bdat_close(reader), add = TRUE)
  chunks <- list(sas7bdat_read_chunk(reader))
  info <- wait_for_decoded(reader, 300)
  expect_equal(info$rows_decoded, 300)
  # Truncate after schema setup, with the producer blocked by the full queue.
  con <- file(path, "r+b")
  seek(con, 100000, origin = "start")
  truncate(con)
  close(con)
  error <- tryCatch({
    repeat {
      chunk <- sas7bdat_read_chunk(reader)
      if (is.null(chunk)) break
      chunks[[length(chunks) + 1L]] <- chunk
    }
    NULL
  }, error = function(e) conditionMessage(e))
  expect_match(error, "Unable to read|row count")
  info <- sas7bdat_info(reader)
  expect_identical(info$status, "error")
  expect_equal(info$file_closes, 1)
  rows <- unlist(lapply(chunks, `[[`, "id"), use.names = FALSE)
  expect_identical(rows, as.double(seq_along(rows)))
  expect_gte(length(rows), 300)
  expect_equal(info$rows_delivered, length(rows))
  expect_error(sas7bdat_read_chunk(reader), "Unable to read|row count")
})

test_that("native arenas preserve long UTF-8 text and every SAS missing tag", {
  skip_if_not_installed("haven")
  path <- tempfile(fileext = ".sas7bdat")
  on.exit(unlink(path))
  tags <- c(LETTERS, "_")
  missing <- vapply(tags, function(tag) {
    bytes <- writeBin(NA_real_, raw(), size = 8L, endian = "little")
    bytes[5L] <- charToRaw(tag)
    readBin(bytes, "double", n = 1L, size = 8L, endian = "little")
  }, double(1))
  input <- data.frame(value = rep(c(1.5, NA_real_, missing), 4),
                      text = rep(c("", strrep("\u4e2d\u6587\u00e9", 200)), 58))
  suppressWarnings(haven::write_sas(input, path))
  expected <- haven::read_sas(path)
  actual <- collect_chunks(path, chunk_rows = 5L, dates = FALSE)$data
  expect_equal(plain_values(actual), plain_values(expected))
  expect_identical(writeBin(actual$value, raw()), writeBin(expected$value, raw()))
})
