# Fail if the workflow's pins drift from DESCRIPTION or a resolver upgrades them.
description <- read.dcf("DESCRIPTION")
entries <- trimws(unlist(strsplit(
  paste(description[1L, c("Imports", "LinkingTo", "Suggests")], collapse = ","),
  ",", fixed = TRUE
)))
entries <- unique(entries[grepl("(>=", entries, fixed = TRUE)])
for (entry in entries) {
  package <- sub(" .*", "", entry)
  minimum <- sub(".*\\(>= ([^)]*)\\)", "\\1", entry)
  stopifnot(requireNamespace(package, quietly = TRUE))
  installed <- utils::packageVersion(package)
  if (installed != minimum) {
    stop(package, ": expected minimum ", minimum, ", installed ", installed)
  }
  message(package, " ", installed)
}
stopifnot(arrow::arrow_with_parquet())
print(arrow::arrow_info())
sessionInfo()
