# Design: Flatten Wiring Retrieve Output

Status: implemented and validated against sample loop drawings.

This document describes the current Loop Extractor workflow and output model.
The tool converts the output of `Retrieve/wiring_retrive.sql` into a flattened
Excel file that engineers can use to verify loop drawing connections quickly.

## Goal

Produce a spreadsheet-friendly output that represents the ordered wiring path
shown in SPI loop drawings:

```text
Device / Field -> Junction Box / Marshalling / Cross Wire -> PLC/DCS IO
```

Primary requirement:

- One row per `INSTRUMENT_NAME` by default.
- Optional grouping by `LOOP_NAME + INSTRUMENT_NAME` when instrument names are
  not unique.

## Workflow

The normal admin workflow is:

1. Run `Retrieve/wiring_retrive.sql` in SQL Developer against the SPI database.
2. Export the SQL result grid to Excel.
3. Run `python -m loop_extractor flatten-excel --input "<export>.xlsx" --max-segments auto`.
4. Send the generated `_flattened.xlsx` file to engineers.

The app can also run the SQL directly through Oracle credentials using
`flatten-db`, but the SQL Developer export workflow is the main operating mode.

## Input

The input is the result of `Retrieve/wiring_retrive.sql`.

Required logical fields include:

- Instrument and loop metadata:
  - `UNIT_NAME`
  - `LOOP_NAME`
  - `INSTRUMENT_NAME`
  - `SERVICE_DESCRIPTION`
  - `PID_NUMBER`
  - `LOOP_DWG_NO`
  - `IO_TYPE`
  - `SYSTEM`
  - `SIGNAL_TYPE_NAME`
- Cable fields:
  - `CABLE_NAME`
  - `CABLE_SET_NAME`
  - `CABLE_SET_SEQ`
  - `CABLE_TYPE_NAME`
  - `ROUTE_LENGTH`
  - `CABLE_GLAND_NAME`
  - `SIGNAL_LEVEL`
- FROM endpoint:
  - `FROM_PANEL_TYPE`
  - `FROM_PANEL`
  - `FROM_TERMINAL_STRIP`
  - `FROM_POS`
  - `FROM_TERMINALS`
  - `FROM_COLOR_TERMINALS`
- TO endpoint:
  - `TO_PANEL_TYPE`
  - `TO_PANEL`
  - `TO_TERMINAL_STRIP`
  - `TO_POS`
  - `TO_TERMINALS`
  - `TO_COLOR_TERMINALS`
- IO assignment:
  - `RACK`
  - `SLOT`
  - `CARD`
  - `CARD_TYPE`
  - `TU_TYPE`
  - `IO_MODULE_TYPE`
  - `CHANNEL`
  - `CS_TAG`

## Output Model

The implemented output is a drawing-like chain:

```text
NODE0 -> CABLE1 -> NODE1 -> CABLE2 -> NODE2 -> ...
```

`NODE0` is seeded from the first non-empty FROM endpoint for the instrument.
Each following cable row contributes one `CABLE{i}` and one `NODE{i}` based on
the next TO endpoint.

Header columns are copied once per instrument:

```text
UNIT_NAME, LOOP_NAME, INSTRUMENT_NAME, SERVICE_DESCRIPTION, PID_NUMBER,
LOOP_DWG_NO, IO_TYPE, SYSTEM, SIGNAL_TYPE_NAME
```

Each node has:

```text
PANEL_TYPE, PANEL, TERMINAL_STRIP, POS, TERMINALS, COLOR_TERMINALS
```

Each cable has:

```text
CABLE_NAME, CABLE_SET_NAME, CABLE_SET_SEQ, CABLE_TYPE_NAME,
ROUTE_LENGTH, CABLE_GLAND_NAME, SIGNAL_LEVEL
```

Control columns:

```text
CABLE_COUNT, HOP_COUNT, OVERFLOW_FLG
```

IO assignment columns are placed at the end:

```text
RACK, SLOT, CARD, CARD_TYPE, TU_TYPE, IO_MODULE_TYPE, CHANNEL, CS_TAG
```

## Ordering Rules

The SQL query is responsible for producing drawing-like order. The Python tool
preserves the row order from the exported result within each instrument group.

Important SQL behavior:

- Normal cable rows and cross wire rows are ordered to match drawing sequence.
- CROSS WIRE direction is normalized in SQL before the Python flatten step.
- Shield/drain or cut-and-tape rows can have null endpoint fields and must not
  break flattening.

## Merge Rules

The flatten step performs two practical merge behaviors:

- If a TO node repeats the same panel and terminal strip as the current node,
  terminal and color details are appended to the current node instead of creating
  a duplicate hop.
- If the same cable identity terminates on a different strip in the same panel,
  strip, terminal, and color details are merged into the existing node. This
  handles cases such as a normal terminal strip plus a shield/drain strip.

Merged values use ` | ` as the separator.

## Multi-Row View

`flatten-excel-multirows` uses the same flattened chain, then splits early node
terminal/color lists by index to make the output easier to read as drawing rows.

Current behavior:

- Split `NODE0`, `NODE1`, and `NODE2` terminal/color details by index.
- Keep later nodes collapsed so cross wire and later mapping details do not
  create unnecessary extra rows.
- Collapse later merged terminal strip/text values to the first visible item for
  readability.

## Segment Cap

`--max-segments` controls the maximum number of cable hops.

- Default: `10`
- Recommended for exports: `--max-segments auto`
- `OVERFLOW_FLG = 1` when the source group has more rows than the configured
  segment cap.

By default unused trailing `CABLE{i}` and `NODE{i}` columns are trimmed from the
output. Use `--fixed-width` to keep all configured columns.

## Validation Checklist

For a known loop drawing, verify:

- `NODE0` starts at the field/device side.
- The cable and node sequence matches the drawing left-to-right.
- Junction box, marshalling, cross wire, PLC/DCS, and IO assignment values match
  the drawing and SPI data.
- Terminal lists and color lists are in drawing order.
- Shield/drain details are kept without creating confusing duplicate hops.
- Final IO columns show the expected `RACK`, `SLOT`, `CARD`, `CARD_TYPE`,
  `TU_TYPE`, `IO_MODULE_TYPE`, `CHANNEL`, and `CS_TAG`.
