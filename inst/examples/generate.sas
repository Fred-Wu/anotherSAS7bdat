/* Synthetic example data for anotherSAS7bdat; no external data are used.
   Run this program from this directory in a SAS Unicode (UTF-8) session.
   On Windows, start SAS with -config "<SASROOT>/nls/u8/sasv9.cfg".
   The three files contain the same 120 rows and eight columns. */
options errorabend;
libname examples ".";

data work.example;
  length id 8 group $9 text $40 amount 8
         visit_date visit_time recorded_at 8 notes $240;
  label id = "Observation identifier"
        group = "Study group"
        text = "Text including Unicode and blank values"
        amount = "Amount with ordinary and special missing values"
        visit_date = "Visit date"
        visit_time = "Visit time"
        recorded_at = "Recorded date and time"
        notes = "Synthetic observation notes";
  format amount 10.2 visit_date yymmdd10. visit_time time8.
         recorded_at datetime20.;

  do id = 1 to 120;
    if mod(id, 2) = 0 then group = "Treatment";
    else group = "Control";
    select (mod(id, 4));
      when (0) text = "";
      when (1) text = "hello";
      when (2) text = "café";
      when (3) text = "中文";
    end;
    amount = (id - 60) * 1.25;
    if id = 10 then amount = .;
    if id = 20 then amount = .A;
    if id = 30 then amount = .Z;
    if id = 40 then amount = ._;
    visit_date = '01JAN2024'd + id - 1;
    visit_time = '09:00:00't + id * 30;
    recorded_at = dhms(visit_date, 0, 0, visit_time);
    if id = 50 then call missing(visit_date, visit_time, recorded_at);
    notes = cats("Synthetic observation ", put(id, 3.));
    output;
  end;
run;

data examples.example_uncompressed(compress=no bufsize=4096);
  set work.example;
run;

/* RLE: run-length encoding. */
data examples.example_rle(compress=char bufsize=4096);
  set work.example;
run;

/* RDC: Ross Data Compression. */
data examples.example_rdc(compress=binary bufsize=4096);
  set work.example;
run;

libname examples clear;
