# Loop Extractor

**Loop Extractor** helps SmartPlant Instrumentation admins export loop drawing
connection data to Excel so engineers can verify wiring paths quickly without
opening each loop drawing in SPI.

The normal workflow is:

1. Run `Retrieve/wiring_retrive.sql` in SQL Developer against the SPI database.
2. Export the SQL result to `.xlsx`.
3. Run this Python tool against the exported Excel file.
4. Share the flattened Excel output with engineers for connection checking.

The flattened output is one row per `INSTRUMENT_NAME` by default. Each row shows
the drawing path as:

```text
NODE0 -> CABLE1 -> NODE1 -> CABLE2 -> NODE2 -> ...
```

Included as inputs/reference:

- `Retrieve/wiring_retrive.sql` - source SPI wiring retrieve query
- `Retrieve/*.xlsx` - local SQL exports and flattened examples
- `Retrieve/HOW_TO_FLATTEN.md` - short operator guide
- `design/flatten_wiring_output_app.md` - implementation notes
- `SPI_DB_Schema/` - schema references

## Usage

Install dependencies once from the project root:

```powershell
python -m pip install -r requirements.txt
```

### 1) Run SQL and export

Open `Retrieve/wiring_retrive.sql` in SQL Developer, run it against the SPI
database, then export the result grid to Excel.

The exported file must contain the SQL result columns, including fields such as
`LOOP_NAME`, `INSTRUMENT_NAME`, `CABLE_NAME`, `FROM_PANEL`, `FROM_TERMINALS`,
`TO_PANEL`, `TO_TERMINALS`, `RACK`, `SLOT`, `CARD`, `CHANNEL`, and `CS_TAG`.

### 2) Flatten the exported Excel file

From the project root:

```powershell
python -m loop_extractor flatten-excel --input "Retrieve\Wiring_retrieve_output.xlsx" --max-segments auto
```

Output defaults to `Retrieve\Wiring_retrieve_output_flattened.xlsx`.

### 3) Optional: loop-drawing multi-row view

Use this when engineers want terminal lists split into separate drawing-style
rows:

```powershell
python -m loop_extractor flatten-excel-multirows --input "Retrieve\Wiring_retrieve_output.xlsx" --max-segments auto
```

The multi-row view splits early node terminals/colors by index while keeping the
same `NODE0 -> CABLE1 -> NODE1` column model.

## Output Columns

Header columns:

```text
UNIT_NAME, LOOP_NAME, INSTRUMENT_NAME, SERVICE_DESCRIPTION, PID_NUMBER,
LOOP_DWG_NO, IO_TYPE, SYSTEM, SIGNAL_TYPE_NAME
```

Path columns:

```text
NODE0_*,
CABLE1_*, NODE1_*,
CABLE2_*, NODE2_*,
...
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

IO assignment columns are placed at the end:

```text
RACK, SLOT, CARD, CARD_TYPE, TU_TYPE, IO_MODULE_TYPE, CHANNEL, CS_TAG
```

Control columns:

```text
CABLE_COUNT, HOP_COUNT, OVERFLOW_FLG
```

## Useful Options

By default the CLI trims unused trailing `CABLE{n}_*` and `NODE{n}_*` columns
across the output file. Use `--fixed-width` to always output all
`--max-segments` columns.

`--max-segments` supports `auto`:

```powershell
python -m loop_extractor flatten-excel --input "Retrieve\Wiring_retrieve_output.xlsx" --max-segments auto --auto-segments-margin 2
```

Use `--key loop+instrument` if `INSTRUMENT_NAME` is not unique across loops:

```powershell
python -m loop_extractor flatten-excel --input "Retrieve\Wiring_retrieve_output.xlsx" --key loop+instrument --max-segments auto
```

## Optional: Direct Oracle Mode

The SQL is read from `Retrieve\wiring_retrive.sql` and executed with the bind
`:unit_name_like`.

Set credentials via environment variables:

```powershell
$env:ORACLE_DSN="host:port/service"
$env:ORACLE_USER="..."
$env:ORACLE_PASSWORD="..."
python -m loop_extractor flatten-db --unit-name-like "UNIT%"
```

Or pass them directly:

```powershell
python -m loop_extractor flatten-db --dsn "host:port/service" --user "..." --password "..." --unit-name-like "UNIT%"
```
