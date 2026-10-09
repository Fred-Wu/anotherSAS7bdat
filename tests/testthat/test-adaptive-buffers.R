test_that("automatic bytes keep sampled rows in full output chunks", {
  skip_if_not_installed("haven")
  path <- tempfile(fileext = ".sas7bdat")
  on.exit(unlink(path))
  input <- data.frame(id = as.double(1:1500),
                      text = rep(c("", "caf\u00e9", "\u4e2d\u6587"), 500))
  suppressWarnings(haven::write_sas(input, path))
  reader <- sas7bdat_open(path, chunk_rows = 600L, dates = FALSE)
  on.exit(sas7bdat_close(reader), add = TRUE)
  before <- sas7bdat_info(reader)
  expect_equal(before$estimation_rows, 0)
  expect_equal(before$estimated_row_bytes, 0)
  chunks <- list(sas7bdat_read_chunk(reader), sas7bdat_read_chunk(reader),
                 sas7bdat_read_chunk(reader))
  expect_identical(vapply(chunks, nrow, integer(1)), c(600L, 600L, 300L))
  expect_equal(plain_values(do.call(rbind, chunks)), plain_values(input))
  expect_null(sas7bdat_read_chunk(reader))
  info <- sas7bdat_info(reader)
  expect_equal(info$estimation_rows, 256)
  expect_gt(info$estimated_row_bytes, 0)
  expect_equal(info$rows_decoded, 1500)
  expect_equal(info$file_opens, 1)
  expect_equal(info$file_closes, 1)
})

test_that("the text estimate adapts when later rows become wider", {
  skip_if_not_installed("haven")
  path <- tempfile(fileext = ".sas7bdat")
  on.exit(unlink(path))
  input <- data.frame(id = as.double(1:1536),
    text = c(rep("", 768), rep(strrep("\u4e2d\u6587", 400), 768)))
  suppressWarnings(haven::write_sas(input, path))
  reader <- sas7bdat_open(path, chunk_rows = 256L, dates = FALSE)
  on.exit(sas7bdat_close(reader), add = TRUE)
  chunks <- list(sas7bdat_read_chunk(reader))
  initial <- wait_for_decoded(reader, 768)
  expect_equal(initial$estimation_rows, 256)
  chunks[[2L]] <- sas7bdat_read_chunk(reader)
  widened <- wait_for_decoded(reader, 1024)
  # Decoding and publishing the estimate have separate atomic counters.
  deadline <- Sys.time() + 5
  while (widened$estimated_row_bytes <= initial$estimated_row_bytes + 1000 && Sys.time() < deadline) {
    Sys.sleep(0.01)
    widened <- sas7bdat_info(reader)
  }
  expect_gt(widened$estimated_row_bytes, initial$estimated_row_bytes + 1000)
  expect_equal(widened$estimation_rows, 256)
  repeat {
    chunk <- sas7bdat_read_chunk(reader)
    if (is.null(chunk)) break
    chunks[[length(chunks) + 1L]] <- chunk
  }
  expect_true(all(vapply(chunks, nrow, integer(1)) == 256L))
  expect_equal(plain_values(do.call(rbind, chunks)), plain_values(input))
})

test_that("sampling crosses small chunks and respects changing n", {
  skip_if_not_installed("haven")
  path <- tempfile(fileext = ".sas7bdat")
  on.exit(unlink(path))
  input <- data.frame(id = as.double(1:1000), text = rep("hello", 1000))
  suppressWarnings(haven::write_sas(input, path))
  reader <- sas7bdat_open(path, chunk_rows = 37L, dates = FALSE)
  on.exit(sas7bdat_close(reader), add = TRUE)
  chunks <- lapply(1:8, function(i) sas7bdat_read_chunk(reader))
  expect_true(all(vapply(chunks, nrow, integer(1)) == 37L))
  expect_equal(sas7bdat_info(reader)$estimation_rows, 256)
  chunks[[9L]] <- sas7bdat_read_chunk(reader, n = 600L)
  expect_equal(nrow(chunks[[9L]]), 600)
  chunks[[10L]] <- sas7bdat_read_chunk(reader, n = 600L)
  expect_equal(nrow(chunks[[10L]]), 104)
  expect_null(sas7bdat_read_chunk(reader))
  expect_equal(plain_values(do.call(rbind, chunks)), plain_values(input))
})

test_that("explicit byte limits remain in force after estimating wide rows", {
  skip_if_not_installed("haven")
  path <- tempfile(fileext = ".sas7bdat")
  on.exit(unlink(path))
  input <- data.frame(id = as.double(1:600), text = rep(strrep("x", 1500), 600))
  suppressWarnings(haven::write_sas(input, path))
  result <- collect_chunks(path, chunk_rows = 600L, chunk_bytes = "1 KiB", dates = FALSE)
  expect_true(all(vapply(result$chunks, nrow, integer(1)) == 1L))
  expect_equal(result$info$estimation_rows, 256)
  expect_gt(result$info$estimated_row_bytes, 1500)
  expect_equal(plain_values(result$data), plain_values(input))
})

test_that("short and empty compressed files require no extra sample reads", {
  for (compression in c("uncompressed", "rle", "rdc")) {
    result <- collect_chunks(example_path(compression), chunk_rows = 1000L)
    expect_equal(length(result$chunks), 1)
    expect_equal(nrow(result$data), 120)
    expect_equal(result$info$estimation_rows, 120)
    expect_gt(result$info$estimated_row_bytes, 0)
    expect_equal(result$info$file_opens, 1)
    expect_equal(result$info$file_closes, 1)
  }
  skip_if_not_installed("haven")
  path <- tempfile(fileext = ".sas7bdat")
  on.exit(unlink(path))
  suppressWarnings(haven::write_sas(data.frame(id = double()), path))
  reader <- sas7bdat_open(path)
  on.exit(sas7bdat_close(reader), add = TRUE)
  expect_null(sas7bdat_read_chunk(reader))
  expect_equal(sas7bdat_info(reader)$estimation_rows, 0)
  expect_equal(sas7bdat_info(reader)$estimated_row_bytes, 0)
})

test_that("numeric-only estimates use selected columns", {
  skip_if_not_installed("haven")
  path <- tempfile(fileext = ".sas7bdat")
  on.exit(unlink(path))
  input <- data.frame(id = as.double(1:600), value = rep(3.5, 600),
                      text = rep(strrep("x", 1000), 600))
  suppressWarnings(haven::write_sas(input, path))
  result <- collect_chunks(path, chunk_rows = 300L, columns = c("value", "id"), dates = FALSE)
  expect_equal(result$info$estimated_row_bytes, 18)
  expect_equal(result$info$estimation_rows, 256)
  expect_equal(plain_values(result$data), plain_values(input[c("value", "id")]))
  expect_identical(vapply(result$chunks, nrow, integer(1)), c(300L, 300L))
})
