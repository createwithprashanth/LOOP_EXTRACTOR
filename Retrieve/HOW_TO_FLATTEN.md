# How to Flatten a Wiring Retrieve Output

This is the normal admin workflow after exporting SPI loop drawing connection
data from SQL Developer.

## 1) Run SQL in SQL Developer

1. Open `Retrieve/wiring_retrive.sql`.
2. Run it against the SPI database.
3. Export the result grid to Excel, for example:

```text
Retrieve\Wiring_retrieve_output_1661P.xlsx
```

The exported Excel file must contain the real SQL result columns. Do not use a
blank workbook or a workbook that only contains the SQL text.

## 2) Install Python Dependencies

Run once from the project root:

```powershell
python -m pip install -r requirements.txt
```

## 3) Run Flatten

Open a terminal in the project root:

```text
C:\D-Drive\Apps\Loop Extractor
```

### One row per instrument

```powershell
python -m loop_extractor flatten-excel --input "Retrieve\<filename>.xlsx" --max-segments auto
```

Example:

```powershell
python -m loop_extractor flatten-excel --input "Retrieve\Wiring_retrieve_output_1661P.xlsx" --max-segments auto
```

Output is written next to the input file with `_flattened` appended:

```text
Retrieve\Wiring_retrieve_output_1661P_flattened.xlsx
```

### One row per wire (loop drawing style)

Use this when engineers want each terminal on its own row, replicating the
loop drawing layout. All common columns (cable, header, IO) are duplicated
across rows for the same instrument.

```powershell
python -m loop_extractor flatten-excel-multirows --input "Retrieve\<filename>.xlsx" --max-segments auto
```

Output is written with `_flattened_multirows` appended:

```text
Retrieve\Wiring_retrieve_output_1661P_flattened_multirows.xlsx
```

## Useful Options

| Option | Default | Description |
|---|---|---|
| `--input` | required | Path to the wiring retrieve output `.xlsx` |
| `--max-segments` | `10` | Max cable segments per instrument. Use `auto` to detect from data. |
| `--output` | `<input>_flattened.xlsx` | Custom output path |
| `--key` | `instrument` | Group by `instrument` or `loop+instrument` |
| `--fixed-width` | off | Keep all configured `NODE` and `CABLE` columns even if unused |

## Output Columns

Each row is one instrument by default. Columns follow a drawing-like chain:

```text
NODE0 -> CABLE1 -> NODE1 -> CABLE2 -> NODE2 -> ...
```

Header columns:

```text
UNIT_NAME, LOOP_NAME, INSTRUMENT_NAME, SERVICE_DESCRIPTION, PID_NUMBER,
LOOP_DWG_NO, IO_TYPE, SYSTEM, SIGNAL_TYPE_NAME
```

Each `NODE` has:

```text
PANEL_TYPE, PANEL, TERMINAL_STRIP, POS, TERMINALS, COLOR_TERMINALS
```

Each `CABLE` has:

```text
CABLE_NAME, CABLE_SET_NAME, CABLE_SET_SEQ, CABLE_TYPE_NAME,
ROUTE_LENGTH, CABLE_GLAND_NAME, SIGNAL_LEVEL
```

IO assignment columns at the end:

```text
RACK, SLOT, CARD, CARD_TYPE, TU_TYPE, IO_MODULE_TYPE, CHANNEL, CS_TAG
```
