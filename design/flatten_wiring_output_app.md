# Design: Flatten Wiring Retrieve Output (1 row per `INSTRUMENT_NAME`)

Status: **Design only** (do not implement yet)

This document proposes an application (or transformation pipeline) that takes the **existing** query output from `Retrieve/wiring_retrive.sql` and produces a **flattened, single-row** representation per instrument.

The current SQL query must **not** be modified for this work.

---

## 1) Goal

Produce a spreadsheet-friendly “single row per instrument” output that represents the **ordered wiring path** shown in SPI loop drawings:

Device / Field → (JB / Marshalling / Cross Wire segments) → PLC/DCS IO

### Primary requirement

- **1 row per `INSTRUMENT_NAME`**

### Constraints / assumptions

- Maximum expected number of segments/hops in a path: **10**
- The existing SQL output is already ordered in a drawing-like sequence (the app must rely on that order).
- Shield/drain “cut & tape” cores may produce **NULL endpoint fields** (this is expected and should not break flattening).

---

## 2) Input

### Source

Use the output of `Retrieve/wiring_retrive.sql` (typically exported to Excel).

Example (local export):

- `Retrieve/Wiring_retrieve_output/Wiring_retrieve_output.xlsx` (or your local copy at `C:\D-Drive\Apps\SPI Queries\Retrieve\Wiring_retrieve_output\Wiring_retrieve_output.xlsx`)

### Required columns (minimum)

The flattening logic relies on these fields (names as in the report output):

- `LOOP_NAME`
- `INSTRUMENT_NAME`
- `SIGNAL_LEVEL`
- `CABLE_ID`, `CABLE_SET_ID`, `CABLE_SET_SEQ`
- `CABLE_NAME`, `CABLE_TYPE_NAME`, `ROUTE_LENGTH`, `CABLE_GLAND_NAME`
- FROM endpoint:
  - `FROM_PANEL_TYPE`, `FROM_PANEL`, `FROM_TERMINAL_STRIP`, `FROM_GROUP_SEQ`, `FROM_TERMINALS`, `FROM_COLOR_TERMINALS`
- TO endpoint:
  - `TO_PANEL_TYPE`, `TO_PANEL`, `TO_TERMINAL_STRIP`, `TO_GROUP_SEQ`, `TO_TERMINALS`, `TO_COLOR_TERMINALS`
- IO assignment / system side (optional but typically present):
  - `RACK`, `SLOT`, `CARD`, `CHANNEL`, `CS_TAG`
- Drawing refs (optional but desired):
  - `PID_NUMBER`, `LOOP_DWG_NO`

---

## 3) Output model

### 3.1) Row key

One output row represents one `INSTRUMENT_NAME`.

If `INSTRUMENT_NAME` is not globally unique, the app must optionally support a composite key:

- `LOOP_NAME + INSTRUMENT_NAME`

This is a configuration option; default remains **one row per `INSTRUMENT_NAME`** per your request.

### 3.2) Segment model (“hop”)

Each input row represents a candidate “segment” in the overall path.

A segment captures:

- Segment ordering index (`SEG_IDX`, 1..10)
- Cable identity:
  - `CABLE_ID`, `CABLE_SET_ID`, `CABLE_SET_SEQ`
  - `CABLE_NAME`, `CABLE_TYPE_NAME`, `ROUTE_LENGTH`, `CABLE_GLAND_NAME`
- Endpoints:
  - FROM: panel type/name, strip, terminals, colors
  - TO: panel type/name, strip, terminals, colors
- Metadata (copied onto the instrument row, not duplicated per segment unless needed):
  - `SERVICE_DESCRIPTION`, `IO_TYPE`, `SYSTEM`, `SIGNAL_TYPE_NAME`, `PID_NUMBER`, `LOOP_DWG_NO`, `UNIT_NAME`

---

## 4) Core logic

### 4.1) Preserve the report’s order

The SQL already enforces a drawing-like order.

The flattening app must:

1. Sort by the exact ordering present in the input export (do not “resort” independently).
2. Process rows sequentially per instrument key.

### 4.2) Merge rule: contiguous segments that share an intermediate endpoint

In loop drawings, consecutive segments often connect at a common panel (e.g., JB, marshaling rack, or PLC panel).

For flattening, consecutive rows are considered part of the same continuous path when:

- `prev.TO_PANEL` matches `next.FROM_PANEL`

Recommended strengthening (to reduce accidental merges where panel names collide):

- Also require `prev.TO_PANEL_TYPE = next.FROM_PANEL_TYPE` when both are non-null.
- Optionally include `TERMINAL_STRIP` match:
  - `prev.TO_TERMINAL_STRIP = next.FROM_TERMINAL_STRIP` when both are non-null.

This “merge rule” is used to build a continuous ordered path, not to collapse rows into one; the app still keeps each segment’s cable properties distinct.

### 4.3) Handling CROSS WIRE rows

The SQL output already normalizes CROSS WIRE direction using `SWAP_FLG`.

Flattening should treat CROSS WIRE as just another segment in the path; no extra direction logic should be introduced in the app.

### 4.4) Missing endpoints (shield/drain cut & tape)

If a row has NULL `FROM_*` or `TO_*` endpoint fields:

- Keep the segment, but do not use it as a “bridge” for merges unless the fields required by the merge rule are present.
- Do not fail the instrument row; leave the segment columns blank for missing values.

### 4.5) Segment cap and overflow behavior

We expect up to **10** segments.

Define overflow behavior if a path exceeds 10:

- Default: keep the first 10 segments and write an `OVERFLOW_FLG = 1`.
- Optionally: store remaining segments in a single “overflow text” column, e.g. `SEGMENTS_OVERFLOW`.

---

## 5) Output schema (columns)

### 5.1) Header (one set per row)

Include a single set of “instrument-level” columns:

- `LOOP_NAME`
- `INSTRUMENT_NAME`
- `SERVICE_DESCRIPTION`
- `PID_NUMBER`
- `LOOP_DWG_NO`
- `IO_TYPE`
- `SYSTEM`
- `SIGNAL_TYPE_NAME`
- `UNIT_NAME`
- `RACK`, `SLOT`, `CARD`, `CHANNEL`, `CS_TAG`

### 5.2) Segment columns (repeated up to 10)

For each `SEG{i}_` (i = 1..10):

- Cable:
  - `SEG{i}_CABLE_NAME`
  - `SEG{i}_CABLE_SET_NAME`
  - `SEG{i}_CABLE_SET_SEQ`
  - `SEG{i}_CABLE_TYPE_NAME`
  - `SEG{i}_ROUTE_LENGTH`
  - `SEG{i}_CABLE_GLAND_NAME`
- FROM endpoint:
  - `SEG{i}_FROM_PANEL_TYPE`
  - `SEG{i}_FROM_PANEL`
  - `SEG{i}_FROM_TERMINAL_STRIP`
  - `SEG{i}_FROM_TERMINALS`
  - `SEG{i}_FROM_COLOR_TERMINALS`
- TO endpoint:
  - `SEG{i}_TO_PANEL_TYPE`
  - `SEG{i}_TO_PANEL`
  - `SEG{i}_TO_TERMINAL_STRIP`
  - `SEG{i}_TO_TERMINALS`
  - `SEG{i}_TO_COLOR_TERMINALS`

Notes:

- We intentionally exclude internal numeric keys (`CABLE_ID`, `CABLE_SET_ID`) from the flattened view unless you want them for traceability. If needed, add `SEG{i}_CABLE_ID` / `SEG{i}_CABLE_SET_ID`.

---

## 6) Implementation options (later)

This design is implementation-agnostic. Candidate implementations:

1. **Python (pandas) CLI**:
   - Reads the Excel export, outputs a flattened Excel/CSV.
   - Easiest to maintain; can enforce segment cap and validations.
2. **Power Query (Excel)**:
   - Convenient for end users, but more difficult to maintain complex sequencing/merging rules.
3. **Small desktop/web app**:
   - Useful if we later add browsing/filtering, drawing previews, or database connections.

For the first iteration, Python CLI is likely the fastest and most reliable.

---

## 7) Validation checklist

For a sample instrument (from loop drawing):

- Segment sequence matches the drawing path left-to-right.
- `SEG1_FROM_PANEL` is the device panel (or field device) and later segments bridge at JB/PLC panels.
- Where “in first to_panel and second row from_panel is same”, the flattened row shows a continuous path with no duplicated intermediate panel confusion.
- CROSS WIRE appears after the associated normal cable within the same connection level (inherited from SQL ordering).
