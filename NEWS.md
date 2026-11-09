# anotherSAS7bdat 0.0.9

* Fixed date and datetime conversion on macOS so missing values and SAS
  special missing codes are preserved exactly.
* Fixed file-reading errors that appeared as "C++ exception (unknown reason)"
  on some systems. These errors now show the underlying problem.
* Fixed missing column labels, SAS formats, and time display when reading
  converted Parquet files into R with Arrow versions earlier than 25.
* Fixed conversion of empty SAS files so the resulting Parquet files can be
  read by Arrow 18.1.0 as well as newer versions.
* Parquet conversion now requires Arrow 18.1.0 or later with Parquet support.
  If either requirement is missing, conversion stops with a clear message
  before opening files. Reading SAS files into R does not require Arrow.
* The minimum required versions are now Rcpp 1.0.14 and hms 0.5.0. Running
  the package tests requires testthat 3.3.0; tests that use haven require
  haven 2.5.5. R 4.1.0 remains the minimum supported R version.
