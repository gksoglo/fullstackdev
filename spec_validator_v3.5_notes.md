# Spec Validator v3.5 - what was wrong in v3.4 and what changed

Test input: `1006.csv` (24 blocks, 136 rows). v3.4 result: **61 values out, 30 not checked**.
v3.5 result: **39 out, 0 not checked, 1 matching warning**.

## Root cause of the all-red DL3PE LHD block
1. The built-in template was a hand-condensed copy of the check sheet: it kept the entry
   `DL3 PE` (with a space) but code matching was `data.includes(tpl) || tpl.includes(data)`.
2. Data code `DL3PE` does not contain `DL3 PE`, but it *does* contain `DL3`. The first
   substring hit was the plain **DL3** part (A3C0527800000: 177.4 / 66.11 / 68.63), so the
   231.7 / 76.17 / 76.4 readings were compared with 177.4 / 66.11 / 68.63 -> 25/25 "out".
   The correct entry is DL3 PE LHD (A3C1170910000: 231.85 +-0.37 / 76.19 +-0.14 / 76.56, 76.5, 76.43).
3. Nothing told you it was a mismatch - a 54 mm deviation was drawn like a 0.01 mm reject.

Other defects found along the way:
* **NH2 missing** from the condensed template (30 values "not checked"). CE/CT/NQ5/SP3 RHD,
  LX3 RHD, NH2 RHD, MV RHD were also absent or merged into the LHD entry.
* Side was ignored on purpose in v3.4, but CE PE has different tolerances per side
  (LHD +-0.1, RHD +-0.15), so side must be part of the match once the template is complete.
* "Fewest out-of-tolerance values wins" row pairing could hide a real reject behind a
  different pairing that happens to look better.
* Float drift at the tolerance edge: `241.76 + 0.1 = 241.85999999999999`, so a reading of
  exactly 241.860 was failed (same for 240.860, 85.010).
* Excel/paste path took only the first word of a header, so `DL3 PE LHD` -> `DL3`.

## What v3.5 does
* **Template regenerated from the sheet** (`spec_validator_tools/gen_template.py`, sheet
  `전체데이터`): 31 sheet blocks -> 26 distinct entries, each with part number, side and the
  sheet's own row order. Re-run it whenever the check sheet changes.
* **Code matching ladder** (most specific wins, never a shorter code swallowing a longer one):
  part number (Excel info line carries 품번) -> exact normalised code (`DL3 PE`=`DL3-PE`=`DL3PE`)
  -> PE suffix on one side only (`DN8` <-> `DN8PE`, `NQ5` <-> `NQ5PE`) -> unambiguous family
  (`CT` -> `CT1`) -> none. For "none" the page lists close codes ("did you mean ...?").
  Then side: same side, else side-neutral entry, else any (with a warning).
* **Row-to-spec pairing** for label-less CSV rows: CMM rows first, then Vernier (as before),
  each group paired by least-squares distance between the row average and the spec window
  centre, never by pass/fail count. If a different pairing would give *fewer* rejects the
  block gets an amber "pairing uncertain" line (this is JWPE RHD in 1006.csv).
* **Mismatch alarm**: a row whose average is > 1 mm outside its window is treated as a wrong
  template/code, not a reject - the block is shown as "not checked" with an amber explanation.
  (Trade-off: a genuine reject worse than 1 mm is also reported this way; change `MISMATCH_MM`.)
* Every product shows which template entry it matched and how. Copy/CSV output unchanged.
* Label fallback for the Excel/paste layout: if the template has nothing for a product, the
  row's own `242.85 (+0.15/-0.15)` label is used as the spec.

## 1006.csv - what is left red, and why it is real
* NQ5PE LHD (blocks 2, 6, 15, 24): F7 242.85 +-0.1, lower limit 242.75; readings 242.724-242.749.
* LX3 LHD (3, 10, 18): F6 235.85 +-0.1, lower limit 235.75; readings 235.709-235.749.
* NQ5PE RHD (8): H7 241.76 +-0.1, lower limit 241.66; readings 241.634 / 241.635.
* JWPE RHD (4): result depends on pairing the two CMM rows with 240.85 (F7) / 240.76 (H7);
  rows are symmetric between the two nominals. v3.5 uses the F/E-then-H order seen in every other
  product (8 out); the opposite pairing gives 5 out. Please confirm which row is which.
* Blocks 1 & 5 (GN7) are digit-for-digit identical, as are the first 3 rows of NQ5PE LHD blocks
  2, 6, 15 - worth checking they were not copied between dates.

## Check-sheet oddities noticed (not changed)
* MV LHD (same part A3C1091750000) appears with three different Vernier sets: 80.64 x3,
  75.75/80.44/80.4 and 79.75/80.44/80.4 - 75.75 is probably a typo for 79.75; NO.5 labels
  its 75.39 row `F7` where the others say `B7`.
* Position labels differ between LHD and RHD of the same product (LX3 F6/F7, H7/H10, B16/B10).
