from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

import pandas as pd


DEFAULT_MAX_SEGMENTS = 10

HEADER_COLS: list[str] = [
    "UNIT_NAME",
    "LOOP_NAME",
    "INSTRUMENT_NAME",
    "SERVICE_DESCRIPTION",
    "PID_NUMBER",
    "LOOP_DWG_NO",
    "IO_TYPE",
    "SYSTEM",
    "SIGNAL_TYPE_NAME",
]

IO_ASSIGN_COLS_REQUIRED: list[str] = ["RACK", "SLOT", "CARD", "CHANNEL", "CS_TAG"]
IO_ASSIGN_COLS_OPTIONAL: list[str] = ["CARD_TYPE", "TU_TYPE", "IO_MODULE_TYPE"]
IO_ASSIGN_COLS: list[str] = [*IO_ASSIGN_COLS_REQUIRED[:3], *IO_ASSIGN_COLS_OPTIONAL, *IO_ASSIGN_COLS_REQUIRED[3:]]

CABLE_COLS: list[str] = [
    "CABLE_NAME",
    "CABLE_SET_NAME",
    "CABLE_SET_SEQ",
    "CABLE_TYPE_NAME",
    "ROUTE_LENGTH",
    "CABLE_GLAND_NAME",
    "SIGNAL_LEVEL",
]

NODE_FIELD_SUFFIXES: list[str] = [
    "PANEL_TYPE",
    "PANEL",
    "TERMINAL_STRIP",
    "POS",
    "TERMINALS",
    "COLOR_TERMINALS",
]

FROM_NODE_COLS: list[str] = [f"FROM_{s}" for s in NODE_FIELD_SUFFIXES]
TO_NODE_COLS: list[str] = [f"TO_{s}" for s in NODE_FIELD_SUFFIXES]


@dataclass(frozen=True)
class FlattenOptions:
    key: tuple[str, ...] = ("INSTRUMENT_NAME",)
    max_segments: int = DEFAULT_MAX_SEGMENTS
    trim_key: bool = True
    fixed_width: bool = False


def _first_non_null(series: pd.Series):
    for value in series.tolist():
        if pd.notna(value):
            return value
    return None


def _require_columns(df: pd.DataFrame, required: Iterable[str]) -> None:
    missing = [c for c in required if c not in df.columns]
    if missing:
        raise ValueError(f"Missing required columns: {', '.join(missing)}")

def _strip_series(value: pd.Series) -> pd.Series:
    return value.astype("string").str.strip()


def _node_from_row(row: pd.Series, *, side: str) -> dict[str, object]:
    if side not in ("FROM", "TO"):
        raise ValueError("side must be 'FROM' or 'TO'")
    out: dict[str, object] = {}
    for suffix in NODE_FIELD_SUFFIXES:
        out[suffix] = row.get(f"{side}_{suffix}")
    return out


def _node_is_empty(node: dict[str, object]) -> bool:
    return all(pd.isna(v) or v is None or (isinstance(v, str) and v.strip() == "") for v in node.values())

def _node_key(node: dict[str, object]) -> tuple[object, object]:
    return (node.get("PANEL"), node.get("TERMINAL_STRIP"))


def _merge_terminals(base: object, extra: object) -> object:
    if pd.isna(extra) or extra is None:
        return base
    if pd.isna(base) or base is None:
        return extra
    base_s = str(base).strip()
    extra_s = str(extra).strip()
    if not extra_s:
        return base
    if not base_s:
        return extra
    if extra_s in base_s.split(" | "):
        return base
    return f"{base_s} | {extra_s}"


def _segment_identity(row: pd.Series) -> tuple[object, ...]:
    """
    Best-effort identity for a cable segment.

    Prefer stable numeric IDs when present; otherwise fall back to name/set/seq.
    """
    if "CABLE_ID" in row and "CABLE_SET_ID" in row:
        return ("ID", row.get("CABLE_ID"), row.get("CABLE_SET_ID"))
    return (
        "NAME",
        row.get("CABLE_NAME"),
        row.get("CABLE_SET_NAME"),
        row.get("CABLE_SET_SEQ"),
    )


def flatten_wiring_output(df: pd.DataFrame, options: FlattenOptions | None = None) -> pd.DataFrame:
    """
    Flatten the SPI wiring retrieve output into 1 row per instrument key.

    Output is a drawing-like chain: NODE0 + CABLE1 + NODE1 + ... per key.

    Input order is preserved: cables are assigned sequentially in the order they
    appear in the provided dataset per key.
    """
    options = options or FlattenOptions()
    if not options.key:
        raise ValueError("FlattenOptions.key must have at least one column")

    _require_columns(df, list(options.key))
    _require_columns(df, HEADER_COLS)
    _require_columns(df, IO_ASSIGN_COLS_REQUIRED)
    _require_columns(df, CABLE_COLS)
    _require_columns(df, FROM_NODE_COLS)
    _require_columns(df, TO_NODE_COLS)

    working = df.copy()
    working["__row_order"] = range(len(working))

    if options.trim_key:
        for k in options.key:
            if k in working.columns:
                working[k] = _strip_series(working[k])

    # Also trim common string fields so merges/keys don't break on trailing spaces.
    for c in ["FROM_PANEL", "TO_PANEL", "FROM_TERMINAL_STRIP", "TO_TERMINAL_STRIP", "INSTRUMENT_NAME", "LOOP_NAME"]:
        if c in working.columns and pd.api.types.is_object_dtype(working[c].dtype):
            working[c] = _strip_series(working[c])

    # Group without sorting to preserve key appearance order.
    grouped = working.groupby(list(options.key), sort=False, dropna=False)

    output_rows: list[dict] = []
    max_used_steps = 0

    for _, group in grouped:
        group = group.sort_values("__row_order", kind="stable")

        row: dict[str, object] = {}
        for col in HEADER_COLS:
            row[col] = _first_non_null(group[col])
        for col in IO_ASSIGN_COLS_REQUIRED:
            row[col] = _first_non_null(group[col])
        for col in IO_ASSIGN_COLS_OPTIONAL:
            row[col] = _first_non_null(group[col]) if col in group.columns else None

        cable_count = len(group)
        row["CABLE_COUNT"] = int(cable_count)
        row["OVERFLOW_FLG"] = 1 if cable_count > options.max_segments else 0

        # Seed NODE0 from the first non-empty FROM node; otherwise from the first TO node.
        node0: dict[str, object] | None = None
        for _, r in group.iterrows():
            candidate = _node_from_row(r, side="FROM")
            if not _node_is_empty(candidate):
                node0 = candidate
                break
        if node0 is None:
            for _, r in group.iterrows():
                candidate = _node_from_row(r, side="TO")
                if not _node_is_empty(candidate):
                    node0 = candidate
                    break
        if node0 is None:
            node0 = {s: None for s in NODE_FIELD_SUFFIXES}

        for suffix, value in node0.items():
            row[f"NODE0_{suffix}"] = value

        current_node = node0
        out_step = 0
        current_seg_id: tuple[object, ...] | None = None
        current_cable_from_node: dict[str, object] = {}

        for i in range(1, options.max_segments + 1):
            idx = i - 1
            if idx >= cable_count:
                for col in CABLE_COLS:
                    row[f"CABLE{i}_{col}"] = None
                for suffix in NODE_FIELD_SUFFIXES:
                    row[f"NODE{i}_{suffix}"] = None
                continue

            seg = group.iloc[idx]
            seg_id = _segment_identity(seg)
            from_node = _node_from_row(seg, side="FROM")
            # Advance node using TO side when present; otherwise keep previous node.
            next_node = _node_from_row(seg, side="TO")
            if _node_is_empty(next_node):
                next_node = current_node

            # If the TO node repeats (same panel + terminal strip), treat this as
            # an additional termination detail at the same node (e.g., shield/drain
            # cut & tape row) and do not create a new cable/node hop.
            if out_step > 0 and _node_key(next_node) == _node_key(current_node) and _node_key(next_node) != (None, None):
                node_idx = out_step
                row[f"NODE{node_idx}_TERMINALS"] = _merge_terminals(
                    row.get(f"NODE{node_idx}_TERMINALS"), next_node.get("TERMINALS")
                )
                row[f"NODE{node_idx}_COLOR_TERMINALS"] = _merge_terminals(
                    row.get(f"NODE{node_idx}_COLOR_TERMINALS"), next_node.get("COLOR_TERMINALS")
                )
                current_node = next_node
                continue

            # If this is the same cable (same identity) but terminates on a different
            # strip in the same panel (e.g., PLC FTBF04 vs ISE BAR), keep it as the
            # same hop and append strip/terminal details onto the existing node.
            # Guard: the FROM side must also match the cable's origin panel — if the
            # FROM panel has changed it means this is a new sequential hop (e.g., a
            # second CROSS WIRE from HLC→AI204 after a first from FTBF07→HLC) even
            # though both share the same synthetic CABLE_SET_ID (CROSS WIRE = 1).
            from_matches_origin = (
                _node_is_empty(from_node)
                or (pd.isna(from_node.get("PANEL")) or from_node.get("PANEL") is None)
                or _node_key(from_node) == _node_key(current_cable_from_node)
            )
            if (
                out_step > 0
                and current_seg_id is not None
                and seg_id == current_seg_id
                and (next_node.get("PANEL") == current_node.get("PANEL"))
                and pd.notna(next_node.get("PANEL"))
                and from_matches_origin
            ):
                node_idx = out_step
                row[f"NODE{node_idx}_TERMINAL_STRIP"] = _merge_terminals(
                    row.get(f"NODE{node_idx}_TERMINAL_STRIP"), next_node.get("TERMINAL_STRIP")
                )
                row[f"NODE{node_idx}_TERMINALS"] = _merge_terminals(
                    row.get(f"NODE{node_idx}_TERMINALS"), next_node.get("TERMINALS")
                )
                row[f"NODE{node_idx}_COLOR_TERMINALS"] = _merge_terminals(
                    row.get(f"NODE{node_idx}_COLOR_TERMINALS"), next_node.get("COLOR_TERMINALS")
                )
                current_node = next_node
                continue

            out_step += 1
            for col in CABLE_COLS:
                row[f"CABLE{out_step}_{col}"] = seg.get(col)
            current_seg_id = seg_id
            current_cable_from_node = from_node

            for suffix, value in next_node.items():
                row[f"NODE{out_step}_{suffix}"] = value
            current_node = next_node

        row["HOP_COUNT"] = int(out_step)
        if out_step > max_used_steps:
            max_used_steps = out_step
        output_rows.append(row)

    out = pd.DataFrame(output_rows)
    # Keep a predictable column order: header, flags, then node/cable chain.
    columns: list[str] = []
    columns.extend(HEADER_COLS)
    columns.extend([f"NODE0_{s}" for s in NODE_FIELD_SUFFIXES])
    chain_len = options.max_segments if options.fixed_width else max_used_steps
    for i in range(1, chain_len + 1):
        columns.extend([f"CABLE{i}_{c}" for c in CABLE_COLS])
        columns.extend([f"NODE{i}_{s}" for s in NODE_FIELD_SUFFIXES])
    # Put IO assignment at the end (logically the "system end" of the path).
    columns.extend(IO_ASSIGN_COLS)
    return out.reindex(columns=columns)
