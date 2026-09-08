#' Read SAS files in continuous chunks
#'
#' Read a SAS file a group of rows at a time. Use `sas7bdat_read()` to run a
#' function on every chunk automatically, or use `sas7bdat_open()` and
#' `sas7bdat_read_chunk()` to request data frames yourself. Inspect the reader
#' with `sas7bdat_info()` and close it with `sas7bdat_close()` when finished.
#'
#' @param path A character string specifying the path to a local `.sas7bdat` file.
#' @param callback A function whose first argument receives each chunk as a data frame.
#' @param chunk_rows A positive whole number specifying the maximum rows per chunk.
#'   Fewer rows are returned when the `chunk_bytes` target is reached first or
#'   when fewer rows remain in the file.
#' @param chunk_bytes Approximate decoded size target for each chunk, as a
#'   numeric byte count or a size string with units B, KB, MB, GB, KiB, MiB,
#'   or GiB (case-insensitive).
#' @param columns A character vector of column names, or `NULL` for all columns.
#' @param encoding A character string specifying the source encoding, or `NULL`
#'   to use the encoding recorded in the file.
#' @param dates A logical value indicating whether to convert recognized SAS
#'   date/time formats to R date/time classes.
#' @param reader A `sas7bdat_reader` object created by `sas7bdat_open()`.
#' @param n A positive whole number specifying the maximum rows for this read,
#'   or `NULL` to use the reader's `chunk_rows`. The reader's `chunk_bytes`
#'   target still applies.
#' @return
#' * `sas7bdat_read()` returns an invisible reading summary: `rows` is the
#'   number of rows passed to the callback, `chunks` is the number of calls,
#'   and `completed` indicates whether reading reached the end of the file.
#'   An empty file calls the callback zero times and returns a completed
#'   summary with zero rows.
#' * `sas7bdat_open()` returns a `sas7bdat_reader` that remembers the reading
#'   position in the open file.
#' * `sas7bdat_read_chunk()` returns a data frame, or `NULL` when no rows remain.
#' * `sas7bdat_info()` returns a snapshot list with `rows_total`, `rows_delivered`,
#'   `columns` (names, types, formats, and labels), `compression`, and `status`
#'   (`open`, `eof`, `error`, or `closed`). `eof` means end of file. Additional
#'   diagnostic counters are `rows_decoded`, `file_opens`, `file_closes`,
#'   `bytes_read`, and `seeks`. Byte and seek counters include metadata setup;
#'   they do not measure R memory use.
#' * `sas7bdat_close()` returns `NULL`, invisibly.
#'
#' @section Closing and stopping:
#' `sas7bdat_read()` closes its reader automatically at the end, on an error or
#' interruption, or when the callback returns exactly `FALSE`.
#'
#' When using `sas7bdat_open()`, call `sas7bdat_close()` when finished. Inside
#' a function, use `on.exit(sas7bdat_close(reader), add = TRUE)` for cleanup even
#' if processing fails. Closing more than once is safe. Reading from a closed
#' reader is an error; open a new reader to start again.
#'
#' @details With `sas7bdat_read()`, each chunk is passed to `callback` as its
#'   first positional argument.
#'   That argument contains the actual data frame for the current chunk. You
#'   choose its name; it does not have to be named `chunk`. The package calls
#'   your function again with the next data frame until reading finishes.
#'
#'   `sas7bdat_read()` returns a reading summary, not the dataset or your
#'   callback's results. Assignments inside the callback are local to that
#'   call. To use rows or calculated results after reading, your callback must
#'   save them in an object outside the callback or write them to a file.
#'   Callback return values are not collected; returning exactly `FALSE`
#'   stops reading.
#'
#'   With `sas7bdat_open()`, the returned reader is a bookmark attached to the
#'   open file, not a data frame. Each `sas7bdat_read_chunk(reader)` returns
#'   the next data frame and advances the position. Assigning it to a variable
#'   replaces that variable's previous value; it does not append rows. In a
#'   loop, stop when the result is `NULL`. Previously returned data frames stay
#'   valid after later reads or closing. `sas7bdat_info()` inspects the reader
#'   without advancing it.
#'
#'   Information returned by `sas7bdat_info()` is a snapshot at the time of the
#'   call. A saved list does not update when rows are read or the reader is
#'   closed. Call `sas7bdat_info()` again to get the current status and counters.
#'
#'   Reopening the file starts from the beginning. Readers cannot be saved with
#'   `saveRDS()` for later reuse or shared between R processes.
#'
#'   The file is opened once and row reading continues across chunk
#'   boundaries without restarting the parser. Metadata setup may seek within
#'   the file once at initialization. Internal SAS RLE and RDC compression are
#'   detected automatically. The file must be seekable; ZIP/gzip wrappers are
#'   unsupported.
#'
#'   Column names are case-sensitive and must be unique. Output columns follow
#'   the requested order. Returned text is converted to UTF-8.
#'
#'   `chunk_rows` sets an upper limit on rows per chunk. Each chunk ends after
#'   a complete row when either the row limit or the approximate decoded size
#'   target, `chunk_bytes`, is reached. If the byte target is reached first,
#'   the chunk contains fewer than `chunk_rows` rows, even before the end of
#'   the file. Row counts can vary between chunks as decoded row sizes vary.
#'   For `sas7bdat_read_chunk()`, supplying `n` overrides the row limit for that
#'   call; the byte target remains in effect. The final chunk may also contain
#'   fewer rows if fewer remain in the file.
#'
#'   The byte target is approximate and may be exceeded by the last row added
#'   to a chunk. It is not a limit on total R memory usage; even a single row
#'   may exceed the target.
#'   MB and GB use powers of 1,000; MiB and GiB use powers of 1,024.
#'
#'   SAS numerics are doubles. Special missing values use haven-compatible tagged
#'   NAs; character padding is trimmed by ReadStat. Column labels and SAS formats
#'   are retained as `label` and `format.sas` attributes. User-defined formats
#'   and SAS catalog files are not interpreted. Files exceeding 2,147,483,647
#'   physical observations are rejected in this version, before counter overflow.
#'
#'   To retain the entire dataset, you must explicitly save the chunks and
#'   combine them, as shown below. The entire decoded dataset
#'   and temporary copies must then fit in memory.
#'   For faster binding of many chunks, use `data.table::rbindlist()` from the
#'   optional data.table package in place of `do.call(rbind, chunks)`.
#'   It returns a `data.table`, which also inherits from `data.frame`.
#'
#' @section Example files:
#' The package includes three files generated with SAS 9.4:
#' * `example_uncompressed.sas7bdat`: uncompressed.
#' * `example_rle.sas7bdat`: RLE compression (`COMPRESS=CHAR`).
#' * `example_rdc.sas7bdat`: RDC compression (`COMPRESS=BINARY`).
#'
#' Each contains the same 120 rows with numeric values, Unicode text, dates,
#' times, datetimes, column labels, and ordinary and special missing values.
#' Use any of these filenames in `system.file()` in the examples below.
#' The SAS program used to generate them is included as `examples/generate.sas`.
#' SAS is not needed to read the bundled files.
#' @export
#' @examples
#' # Read the entire file into sas_data using a callback.
#' path <- system.file("examples", "example_uncompressed.sas7bdat",
#'                     package = "anotherSAS7bdat")
#' chunks <- list()
#'
#' sas7bdat_read(
#'   path,
#'   chunk_rows = 25,
#'   callback = function(data) {
#'     chunks[[length(chunks) + 1L]] <<- data
#'   }
#' )
#'
#' sas_data <- do.call(rbind, chunks)
#' # Faster alternative with data.table installed:
#' # sas_data <- data.table::rbindlist(chunks, use.names = TRUE)
#' rm(chunks)
#'
#' # Read the entire RLE-compressed file using a reader.
#' path <- system.file("examples", "example_rle.sas7bdat",
#'                     package = "anotherSAS7bdat")
#' reader <- sas7bdat_open(path, chunk_rows = 25)
#' chunks <- list()
#'
#' repeat {
#'   data <- sas7bdat_read_chunk(reader)
#'   if (is.null(data)) break
#'   chunks[[length(chunks) + 1L]] <- data
#' }
#'
#' sas7bdat_close(reader)
#'
#' sas_data <- do.call(rbind, chunks)
#' # Faster alternative with data.table installed:
#' # sas_data <- data.table::rbindlist(chunks, use.names = TRUE)
#' rm(chunks)
#' sas7bdat_info(reader)$status  # "closed"
sas7bdat_read <- function(path, callback, chunk_rows = 100000L,
                         chunk_bytes = "128 MiB", columns = NULL,
                         encoding = NULL, dates = TRUE) {
  if (missing(callback)) {
    stop(paste0("Supply `callback`: a function to run on each chunk, for example ",
                "callback = function(chunk) print(nrow(chunk)). ",
                "To request data frames yourself, use sas7bdat_open() followed by ",
                "sas7bdat_read_chunk(). See ?sas7bdat_read for examples."), call. = FALSE)
  }
  if (!is.function(callback)) stop("`callback` must be a function.", call. = FALSE)
  reader <- sas7bdat_open(path, chunk_rows, chunk_bytes, columns, encoding, dates)
  on.exit(sas7bdat_close(reader), add = TRUE)
  rows <- 0
  chunks <- 0
  completed <- FALSE
  repeat {
    chunk <- sas7bdat_read_chunk(reader)
    if (is.null(chunk)) {
      completed <- TRUE
      break
    }
    rows <- rows + nrow(chunk)
    chunks <- chunks + 1
    keep_going <- !identical(callback(chunk), FALSE)
    rm(chunk)
    if (!keep_going) break
  }
  invisible(list(rows = rows, chunks = chunks, completed = completed))
}

#' @rdname sas7bdat_read
#' @export
sas7bdat_open <- function(path, chunk_rows = 100000L,
                         chunk_bytes = "128 MiB", columns = NULL,
                         encoding = NULL, dates = TRUE) {
  scalar_string(path, "path")
  if (!file.exists(path) || isTRUE(file.info(path)$isdir)) {
    stop("`path` must identify an existing file.", call. = FALSE)
  }
  if (grepl("\\.(gz|zip|bz2|xz)$", path, ignore.case = TRUE)) {
    stop("External compression is unsupported; supply the .sas7bdat file.", call. = FALSE)
  }
  chunk_rows <- row_limit(chunk_rows, "chunk_rows")
  chunk_bytes <- byte_limit(chunk_bytes)
  if (!is.null(columns) && (!is.character(columns) || !length(columns) ||
      anyNA(columns) || any(!nzchar(columns)) || anyDuplicated(columns))) {
    stop("`columns` must be NULL or unique, nonempty column names.", call. = FALSE)
  }
  if (!is.null(encoding)) scalar_string(encoding, "encoding")
  if (!is.logical(dates) || length(dates) != 1L || is.na(dates)) {
    stop("`dates` must be TRUE or FALSE.", call. = FALSE)
  }
  path <- enc2utf8(normalizePath(path, winslash = "/", mustWork = TRUE))
  ptr <- native_open(path, if (is.null(columns)) character() else enc2utf8(columns),
                     if (is.null(encoding)) "" else encoding, floor(chunk_bytes))
  structure(list(ptr = ptr, chunk_rows = chunk_rows, dates = dates),
            class = "sas7bdat_reader")
}

#' @rdname sas7bdat_read
#' @export
sas7bdat_read_chunk <- function(reader, n = NULL) {
  check_reader(reader)
  if (is.null(n)) n <- reader$chunk_rows
  n <- row_limit(n, "n")
  chunk <- native_next(reader$ptr, n)
  if (is.null(chunk) || !reader$dates) return(chunk)
  for (j in seq_along(chunk)) {
    x <- chunk[[j]]
    fmt <- attr(x, "format.sas", exact = TRUE)
    if (!is.double(x) || is.null(fmt)) next
    kind <- sas_date_kind(fmt)
    if (kind == "numeric") next
    # Avoid arithmetic on tagged NAs, retaining their payloads exactly.
    if (kind != "time") {
      valid <- !is.na(x)
      x[valid] <- x[valid] - if (kind == "date") 3653 else 3653 * 86400
    }
    if (kind == "date") class(x) <- "Date"
    if (kind == "datetime") {
      class(x) <- c("POSIXct", "POSIXt")
      attr(x, "tzone") <- "UTC"
    }
    if (kind == "time") {
      class(x) <- "difftime"
      attr(x, "units") <- "secs"
    }
    chunk[[j]] <- x
  }
  chunk
}

#' @rdname sas7bdat_read
#' @export
sas7bdat_close <- function(reader) {
  check_reader(reader)
  native_close(reader$ptr)
  invisible(NULL)
}

#' @rdname sas7bdat_read
#' @export
sas7bdat_info <- function(reader) {
  check_reader(reader)
  native_info(reader$ptr)
}

#' @export
print.sas7bdat_reader <- function(x, ...) {
  info <- sas7bdat_info(x)
  cat("<sas7bdat_reader> ", info$status, "\n", sep = "")
  cat("  ", info$path, "\n", sep = "")
  cat("  ", info$rows_delivered, " / ", info$rows_total, " rows; ",
      nrow(info$columns), " selected columns; ", info$compression, "\n", sep = "")
  invisible(x)
}

scalar_string <- function(x, name) {
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    stop(sprintf("`%s` must be one nonempty string.", name), call. = FALSE)
  }
}

row_limit <- function(x, name) {
  if (!is.numeric(x) || length(x) != 1L || is.na(x) || !is.finite(x) ||
      x < 1 || x > .Machine$integer.max || x != floor(x)) {
    stop(sprintf("`%s` must be a positive whole number <= .Machine$integer.max.", name),
         call. = FALSE)
  }
  as.integer(x)
}

byte_limit <- function(x) {
  message <- paste0("`chunk_bytes` must be a positive byte count or a size such as ",
                    "\"64 MiB\" or \"128 MB\" (at most 2^53 - 1 bytes).")
  if (is.character(x) && length(x) == 1L && !is.na(x)) {
    pattern <- "^\\s*([0-9]+(?:\\.[0-9]+)?|\\.[0-9]+)\\s*(B|KB|MB|GB|KiB|MiB|GiB)\\s*$"
    parts <- regmatches(x, regexec(pattern, x, ignore.case = TRUE, perl = TRUE))[[1L]]
    if (length(parts) != 3L) stop(message, call. = FALSE)
    multipliers <- c(b = 1, kb = 1000, mb = 1000^2, gb = 1000^3,
                     kib = 1024, mib = 1024^2, gib = 1024^3)
    x <- as.numeric(parts[2L]) * unname(multipliers[tolower(parts[3L])])
  }
  if (!is.numeric(x) || length(x) != 1L || is.na(x) || !is.finite(x) ||
      x < 1 || x > 2^53 - 1) stop(message, call. = FALSE)
  floor(x)
}

check_reader <- function(x) {
  if (!inherits(x, "sas7bdat_reader") || typeof(x$ptr) != "externalptr") {
    stop("`reader` must be created by sas7bdat_open().", call. = FALSE)
  }
}

sas_date_kind <- function(fmt) {
  fmt <- toupper(fmt)
  if (grepl("^(DATETIME|DATEAMPM|MDYAMPM|DT|NLDATM|IS8601D[NTZ]|[BE]8601(D[NTXZ]|LX))", fmt))
    return("datetime")
  if (grepl("^(DATE|NLDATE|DOWNAME|DAY|WEEK|MON|QTR|YEAR|MMDDYY|DDMMYY|YY|MMYY|WORDDAT|JULIAN|JULDAY|NENGO|PDJUL[GI]|(IS|B|E)8601DA)", fmt))
    return("date")
  if (grepl("^(TIME|NLTIM|TOD|HOUR|HHMM|MMSS|(IS|B|E)8601T|[BE]8601LZ)", fmt))
    return("time")
  "numeric"
}
