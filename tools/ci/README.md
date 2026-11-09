# Platform checks

`R-CMD-check.yaml` runs on pushes, pull requests, and manual dispatches.
All jobs fail on `R CMD check` warnings or errors and retain their check logs.

| Platform | R | Compiler/runtime | Arrow |
| --- | --- | --- | --- |
| Debian (R-hub `debian-clang` image) | devel | GCC/libstdc++ and Clang 23/libc++ | Parquet |
| Fedora (R-hub `gcc16` image) | devel | GCC/libstdc++ and Clang/libc++ | Parquet |
| Debian, GCC | devel | GCC/libstdc++ | Installed without libarrow |
| macOS 15 and 26, Intel and ARM | release and oldrel-1 | Apple Clang/libc++ | Parquet |
| Ubuntu and Windows | release | Runner default | Parquet |

These jobs cover the OS/compiler/runtime families and R release lines involved
in the CRAN failures. They are not exact replicas of CRAN's machines: the Debian
image uses stable Debian rather than testing, compiler patch versions can differ,
and GitHub no longer supplies the macOS 13 runners used by several CRAN flavors.
Linux jobs print their OS, R, compiler configuration, and Arrow capabilities.

Linux dependencies, including Rcpp, haven, and Arrow, are built from source with
the selected compiler. Clang explicitly uses libc++, as on CRAN's Fedora Clang
machine. The Parquet jobs require working Parquet support; the separate stub job
requires Arrow to load without it. This prevents an unsuccessful Arrow build
from silently skipping all Parquet tests in a full-feature job.

The container scripts can also run locally in the corresponding R-hub image:

```sh
export CI_COMPILER=clang       # gcc or clang
export CI_ARROW=parquet        # parquet or stub
export R_MAKEVARS_USER=/tmp/anotherSAS7bdat-ci.Makevars
export R_LIBS_USER=/tmp/anotherSAS7bdat-ci-library
bash tools/ci/setup-linux.sh
Rscript tools/ci/install-dependencies.R
Rscript -e 'rcmdcheck::rcmdcheck(args=c("--no-manual", "--as-cran"), error_on="warning")'
```

Use a disposable container: setup installs system dependencies and writes the
specified Makevars and package library. The `tools` directory is excluded from
the CRAN source package.
