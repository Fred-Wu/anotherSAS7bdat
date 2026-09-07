ReadStat SAS reader sources in src/readstat/ are bundled from:

https://github.com/WizardMac/ReadStat
Commit: 78bb8a9419e9aa505746bdb5c71683a203da53e7
Retrieved: 2026-09-07

The MIT license is reproduced in LICENSE.ReadStat. Only the SAS7BDAT reader
and required common sources are compiled. The common SAS source references
writer utilities, so readstat_writer.c is also included; no write API is exposed.

Local modification: sas/readstat_sas7bdat_read.c rejects physical observation
counts above INT_MAX immediately after decoding the count, before upstream
32-bit counters truncate it. ReadStat's public value callback uses an int index.
This first version supports files larger than 4 GiB, but does not claim support
for more than 2,147,483,647 physical observations.

The C++ adapter calls native libiconv entry points on its worker thread, never
the R API wrappers Riconv_open/Riconv/Riconv_close. On Windows the raw libiconv
symbols are supplied by R's Riconv.dll, matching the iconv.h shipped with R.
No pause/resume changes were made to ReadStat: its callback stack remains alive
and waits for each new request. Its metadata seeks run once per reader.
