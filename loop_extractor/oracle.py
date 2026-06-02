from __future__ import annotations

from dataclasses import dataclass

import pandas as pd


@dataclass(frozen=True)
class OracleConfig:
    user: str
    password: str
    dsn: str


def fetch_query_dataframe(
    *,
    config: OracleConfig,
    sql_text: str,
    params: dict | None = None,
    arraysize: int = 1000,
) -> pd.DataFrame:
    """
    Execute a (read-only) query and return a DataFrame.

    Requires `oracledb` (python-oracledb).
    """
    try:
        import oracledb  # type: ignore
    except Exception as exc:  # pragma: no cover
        raise RuntimeError(
            "Oracle mode requires the 'oracledb' package. Install requirements.txt first."
        ) from exc

    params = params or {}

    with oracledb.connect(user=config.user, password=config.password, dsn=config.dsn) as conn:
        with conn.cursor() as cursor:
            cursor.arraysize = arraysize
            cursor.execute(sql_text, params)
            columns = [d[0] for d in cursor.description]
            rows = cursor.fetchall()
    return pd.DataFrame.from_records(rows, columns=columns)

