"""Sample catalog refresh cron, run state, and relation statistics read-only.

Each poll uses a fresh PostgreSQL connection through the existing local SSH
tunnel. Snapshots are appended as JSON Lines so samples taken immediately
before, during, and after each refresh can be compared later.
"""

from __future__ import annotations

import argparse
from datetime import date, datetime, time as datetime_time, timezone
import json
from pathlib import Path
import sys
import time

import psycopg


RELATIONS = (
    "catalog_items_read",
    "catalog_item_facet_values_read",
    "catalog_size_facets_read",
    "catalog_effective_size_membership_read",
    "catalog_facets_cache",
    "catalog_static_size_facets_cache",
)
DEFAULT_INTERVAL_SECONDS = 15
MAX_DURATION_SECONDS = 2 * 60 * 60
MAX_SAMPLES = 480
STATEMENT_TIMEOUT_MS = 10_000


def json_default(value: object) -> str:
    if isinstance(value, (datetime, date, datetime_time)):
        return value.isoformat()
    raise TypeError(f"Cannot serialize {type(value).__name__}")


def db_connection():
    # libpq reads the user's pgpass.conf; credentials are never passed here.
    return psycopg.connect(
        "host=127.0.0.1 port=15432 dbname=postgres user=codex_reader",
        connect_timeout=5,
    )


def database_snapshot() -> dict:
    connection = db_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute("BEGIN READ ONLY")
            try:
                cursor.execute(f"SET LOCAL statement_timeout = '{STATEMENT_TIMEOUT_MS}ms'")

                cursor.execute(
                    """
                    select active
                    from cron.job
                    where jobname = 'catalog-read-model-refresh'
                    order by jobid
                    limit 1
                    """
                )
                cron_row = cursor.fetchone()
                cron_active = cron_row[0] if cron_row else None

                cursor.execute(
                    """
                    select requested_version, completed_version, last_status,
                           last_duration_ms, refresh_started_at, refresh_completed_at
                    from public.catalog_read_model_refresh_state
                    where singleton
                    """
                )
                state_row = cursor.fetchone()
                refresh_state = None
                if state_row:
                    refresh_state = {
                        "requested_version": state_row[0],
                        "completed_version": state_row[1],
                        "last_status": state_row[2],
                        "last_duration_ms": state_row[3],
                        "refresh_started_at": state_row[4],
                        "refresh_completed_at": state_row[5],
                    }

                cursor.execute(
                    """
                    select exists (
                      select 1
                      from pg_locks l
                      where l.locktype = 'advisory'
                        and l.classid = 0::oid
                        and l.objid = hashtext('catalog_items_read_refresh')::oid
                        and l.objsubid = 1
                        and l.granted
                    )
                    """
                )
                refresh_lock_active = cursor.fetchone()[0]

                cursor.execute(
                    """
                    select run_id, started_at, completed_at, duration_ms, outcome,
                           target_version, requested_after, failure_phase, error_sqlstate
                    from public.catalog_refresh_runs
                    order by run_id desc
                    limit 1
                    """
                )
                run_row = cursor.fetchone()
                latest_run = None
                if run_row:
                    latest_run = {
                        "run_id": run_row[0],
                        "started_at": run_row[1],
                        "completed_at": run_row[2],
                        "duration_ms": run_row[3],
                        "outcome": run_row[4],
                        "target_version": run_row[5],
                        "requested_after": run_row[6],
                        "failure_phase": run_row[7],
                        "error_sqlstate": run_row[8],
                    }

                cursor.execute(
                    """
                    select c.relname, c.relkind, s.n_live_tup, s.n_dead_tup,
                           s.n_tup_ins, s.n_tup_upd, s.n_tup_del,
                           s.vacuum_count, s.autovacuum_count, s.last_vacuum,
                           s.last_autovacuum,
                           pg_relation_size(c.oid) as heap_bytes,
                           pg_indexes_size(c.oid) as index_bytes,
                           pg_total_relation_size(c.oid) as total_bytes
                    from pg_class c
                    join pg_namespace n on n.oid = c.relnamespace
                    left join pg_stat_all_tables s on s.relid = c.oid
                    where n.nspname = 'public' and c.relname = any(%s)
                    order by c.relname
                    """,
                    (list(RELATIONS),),
                )
                relation_columns = [item.name for item in cursor.description]
                relations = [dict(zip(relation_columns, row)) for row in cursor.fetchall()]

                cursor.execute("select clock_timestamp()")
                checked_at = cursor.fetchone()[0]

                return {
                    "sampled_at_utc": checked_at,
                    "cron_active": cron_active,
                    "refresh_state": refresh_state,
                    "refresh_lock_active": refresh_lock_active,
                    "latest_run": latest_run,
                    "relations": relations,
                }
            finally:
                cursor.execute("ROLLBACK")
    finally:
        connection.close()


def append_snapshot(output: Path, snapshot: dict) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(snapshot, default=json_default, separators=(",", ":")))
        handle.write("\n")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--once", action="store_true", help="write exactly one snapshot")
    mode.add_argument(
        "--duration",
        type=float,
        metavar="SECONDS",
        help=f"watch for up to {MAX_DURATION_SECONDS} seconds",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=DEFAULT_INTERVAL_SECONDS,
        metavar="SECONDS",
        help=f"poll interval, minimum 10 seconds (default {DEFAULT_INTERVAL_SECONDS})",
    )
    parser.add_argument("--output", required=True, type=Path, help="workspace JSONL output path")
    args = parser.parse_args(argv)
    if args.interval < 10:
        parser.error("--interval must be at least 10 seconds")
    if args.duration is not None and not 10 <= args.duration <= MAX_DURATION_SECONDS:
        parser.error(f"--duration must be between 10 and {MAX_DURATION_SECONDS} seconds")
    if args.duration is not None and int(args.duration // args.interval) + 1 > MAX_SAMPLES:
        parser.error(f"duration/interval would exceed the {MAX_SAMPLES}-sample output limit")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    started = time.monotonic()
    samples = 0
    while True:
        try:
            snapshot = database_snapshot()
            snapshot["sample_error"] = None
        except Exception as exc:  # Keep connection/query error details out of the log.
            snapshot = {
                "sampled_at_utc": datetime.now(timezone.utc),
                "sample_error": type(exc).__name__,
            }
        append_snapshot(args.output, snapshot)
        samples += 1

        if args.once:
            return 0 if snapshot.get("sample_error") is None else 1
        elapsed = time.monotonic() - started
        if samples >= MAX_SAMPLES or elapsed >= args.duration:
            break
        time.sleep(min(args.interval, max(0.0, args.duration - elapsed)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
