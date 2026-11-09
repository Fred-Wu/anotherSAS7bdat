# anotherSAS7bdat 0.0.8

* Require Arrow >= 18.1.0 for the batch writer API, and reject older versions
  before opening files. Align dependency bounds, examples, and test skips;
  check the minimum dependency set on Linux, Windows, and both macOS architectures.
* Preserve the exact missing-value payload during native date and datetime
  conversion on optimized macOS builds.
* Preserve native worker error messages across C++ runtimes, including Fedora
  Clang/libc++, without transferring stored exception objects.
* Detect Arrow installations without Parquet support before conversion, and
  skip Parquet examples and integration tests when that capability is absent.
* Restore Parquet column labels and `hms` times with Arrow versions before 25,
  which do not expose field metadata in R.
* Remove macOS debug bundles created by configure's compiler probes.
* Expand CI to Debian and Fedora with GCC and Clang, an Arrow installation
  without Parquet support, and current/previous R releases on Intel and ARM macOS.
