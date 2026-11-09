options(repos = c(CRAN = "https://cloud.r-project.org"), Ncpus = 2L,
        timeout = 1200)

mode <- Sys.getenv("CI_ARROW")
stopifnot(mode %in% c("parquet", "no-parquet"))

# Do not reuse binary Rcpp/haven/Arrow builds from another C++ runtime.
packages <- c("Rcpp", "hms", "testthat", "haven", "rcmdcheck", "arrow")
available <- available.packages()
dependencies <- tools::package_dependencies(
  packages, db = available, which = c("Depends", "Imports", "LinkingTo"),
  recursive = TRUE
)
packages <- unique(c(unlist(dependencies, use.names = FALSE), packages))
packages <- intersect(packages, rownames(available))

Sys.setenv(
  LIBARROW_BINARY = "false",
  LIBARROW_BUILD = "true",
  LIBARROW_DOWNLOAD = "false",
  ARROW_R_DEV = "true",
  LIBARROW_MINIMAL = "true",
  ARROW_PARQUET = if (mode == "parquet") "ON" else "OFF",
  ARROW_COMPUTE = "ON",
  ARROW_WITH_SNAPPY = "ON",
  # Avoid an installed system libarrow with a different C++ ABI.
  ARROW_USE_PKG_CONFIG = "false",
  MAKEFLAGS = "-j2"
)
install.packages(setdiff(packages, "arrow"), type = "source",
                 lib = Sys.getenv("R_LIBS_USER"))
# Parallel package installation clears MAKEFLAGS. Install Arrow separately so
# its C++ build respects the two-worker limit, including on large local hosts.
install.packages("arrow", type = "source", lib = Sys.getenv("R_LIBS_USER"),
                 Ncpus = 1L)

for (package in packages) {
  stopifnot(requireNamespace(package, quietly = TRUE))
  stopifnot(normalizePath(dirname(find.package(package))) ==
              normalizePath(Sys.getenv("R_LIBS_USER")))
}
# A failed optional C++ build must fail the job, not silently skip Parquet tests.
stopifnot(identical(arrow::arrow_with_parquet(), mode == "parquet"))
