# Platform checks

`R-CMD-check.yaml` runs on pushes, pull requests, and manual dispatches.
All jobs fail on `R CMD check` warnings or errors and retain their check logs.

| Platform | R | Compiler/runtime | Arrow |
| --- | --- | --- | --- |
| Debian (R-hub `debian-clang` image) | devel | GCC/libstdc++ and Clang 23/libc++ | Parquet |
| Fedora (R-hub `gcc16` image) | devel | GCC/libstdc++ and Clang/libc++ | Parquet |
| Debian, GCC | devel | GCC/libstdc++ | Built without Parquet |
| macOS 15 and 26, Intel and ARM | release and oldrel-1 | Apple Clang/libc++ | Parquet |
| Ubuntu and Windows | release and oldrel-1 | Runner default | Parquet |
| Ubuntu 24.04, Windows, macOS Intel and ARM | 4.4 | Runner default | 18.1.0, with minimum direct dependencies |
| Ubuntu 22.04 | 4.1 | Runner default | 18.1.0, with minimum direct dependencies |

These jobs cover the OS/compiler/runtime families and R release lines involved
in the CRAN failures. They are not exact replicas of CRAN's machines: the Debian
image uses stable Debian rather than testing, compiler patch versions can differ,
and GitHub no longer supplies the macOS 13 runners used by several CRAN flavors.
Linux jobs print their OS, R, compiler configuration, and Arrow capabilities.

## Dependency bounds

| Dependency | Minimum | Reason |
| --- | --- | --- |
| R | 4.1.0 | Supported R baseline; all pinned direct dependencies support it. |
| Rcpp | 1.0.14 | Supported native-build baseline incorporating the R 4.5 API compatibility fixes. Keep `Imports` and `LinkingTo` in sync. |
| hms | 0.5.0 | Introduced the imported `new_hms()` constructor. |
| utils | Bundled with R | Progress-bar and package-version APIs; no separate package version needed. |
| testthat | 3.3.0 | Supports our mocking APIs and removes legacy C mocking code that fails to compile with newer R. |
| haven | 2.5.5 | Test-fixture reader/writer and tagged NAs; includes ReadStat fixes for stricter GCC diagnostics. |
| arrow | 18.1.0 | First CRAN release with `ParquetFileWriter$WriteBatch()`. Parquet support is also required. |

The minimum-dependency jobs pin every versioned direct dependency, then run
`verify-minimum-dependencies.R` to compare the installed versions with
`DESCRIPTION`. This fails on accidental upgrades or stale workflow pins.
These jobs use R 4.4 because archived native packages can use R APIs removed
in newer R. A lower bound does not promise that every old dependency can be
built with every future R/compiler; the release, oldrel, and devel jobs test
current dependencies on those toolchains. An additional Linux job checks the
declared R 4.1 baseline with the same minimum dependencies.

Arrow and haven remain optional: ordinary SAS reading does not require either.
Parquet conversion rejects old Arrow versions before checking capabilities or
opening files; examples and integration tests use the same minimum. The
package itself needs C++17, threads, and iconv; optional Arrow source builds
can have additional compiler/library requirements determined by Arrow's version.

Sources: [Arrow 18.1.0 release notes](https://arrow.apache.org/docs/18.1/r/news/index.html),
[hms release notes](https://hms.tidyverse.org/news/index.html),
[testthat release notes](https://testthat.r-lib.org/news/index.html),
[haven release notes](https://haven.tidyverse.org/news/index.html), and
[Rcpp release notes](https://github.com/RcppCore/Rcpp/blob/master/inst/NEWS.Rd).

Linux dependencies, including Rcpp, haven, and Arrow, are built from source with
the selected compiler. Clang explicitly uses libc++, as on CRAN's Fedora Clang
machine. The Parquet jobs require working Parquet support; the separate no-Parquet job
requires Arrow to load without Parquet. This prevents an unsuccessful Arrow build
from silently skipping all Parquet tests in a full-feature job.

The container scripts can also run locally in the corresponding R-hub image:

```sh
export CI_COMPILER=clang       # gcc or clang
export CI_ARROW=parquet        # parquet or no-parquet
export R_MAKEVARS_USER=/tmp/anotherSAS7bdat-ci.Makevars
export R_LIBS_USER=/tmp/anotherSAS7bdat-ci-library
bash tools/ci/setup-linux.sh
Rscript tools/ci/install-dependencies.R
Rscript -e 'rcmdcheck::rcmdcheck(args=c("--no-manual", "--as-cran"), error_on="warning")'
```

Use a disposable container: setup installs system dependencies and writes the
specified Makevars and package library. The `tools` directory is excluded from
the CRAN source package.
