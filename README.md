# Loop Extractor

This repo will host the **Loop Extractor** Python app that flattens the output of the existing SPI wiring retrieve query into **one row per `INSTRUMENT_NAME`**.

Included as inputs/reference:

- `Retrieve/wiring_retrive.sql` (source query — do not change for the app)
- `Retrieve/Wiring_retrieve_output.xlsx` (sample output)
- `design/flatten_wiring_output_app.md` (design doc)
- `SPI_DB_Schema/` (schema references)

## Usage (Python CLI)

Install deps:

```powershell
python -m pip install -r requirements.txt
```

### 1) Flatten an exported Excel file

```powershell
python -m loop_extractor flatten-excel --input Retrieve\Wiring_retrieve_output.xlsx
```

Output defaults to `Retrieve\Wiring_retrieve_output_flattened.xlsx`.

### 1b) Flatten but output multiple rows (loop-drawing style)

Splits `NODE0_TERMINALS` (e.g. `+, -`) into separate rows.

```powershell
python -m loop_extractor flatten-excel-multirows --input Retrieve\Wiring_retrieve_output.xlsx
```

The flattened format is a drawing-like chain:
`NODE0_* + CABLE1_* + NODE1_* + ...` (up to 10 cables / 11 nodes).

By default the CLI trims unused trailing `CABLE{n}_*` / `NODE{n}_*` columns across the output file. Use `--fixed-width` to always output all `--max-segments` columns.

`--max-segments` supports `auto`:

```powershell
python -m loop_extractor flatten-excel --input Retrieve\Wiring_retrieve_output.xlsx --max-segments auto --auto-segments-margin 2
```

### 2) Run the SQL against Oracle (read-only) and flatten

The SQL is read from `Retrieve\wiring_retrive.sql` and executed with the bind `:unit_name_like`.

Set credentials via env vars:

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
