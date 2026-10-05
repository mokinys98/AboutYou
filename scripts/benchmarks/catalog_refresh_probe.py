"""Probe authenticated catalog APIs around one naturally requested refresh.

The session token is read with hidden input and is never serialized. Database
snapshots use the read-only PostgreSQL tunnel only. The probe does not request
or trigger a catalog refresh and does not clear either API cache.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import getpass
import http.client
import json
from pathlib import Path
import sys
import time
from urllib.parse import urlparse

import psycopg


API_HOST = "aboutyou-private-catalog-api.aurimas-zvirb.workers.dev"
API_ORIGIN = f"https://{API_HOST}"
RELATIONS = (
    "catalog_items_read",
    "catalog_item_facet_values_read",
    "catalog_effective_size_membership_read",
)
REFRESH_LOCK_MODES = {"ExclusiveLock", "AccessExclusiveLock"}
ENDPOINTS = (
    ("catalog", "/v1/catalog?"),
    ("facets", "/v1/catalog/facets?"),
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def db_connection():
    # libpq reads the user's pgpass.conf; never pass or print a password.
    return psycopg.connect(
        "host=127.0.0.1 port=15432 dbname=postgres user=codex_reader "
        "options=-cstatement_timeout=15000",
        connect_timeout=5,
    )


def database_snapshot() -> dict:
    connection = db_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute("BEGIN READ ONLY")
            try:
                cursor.execute(
                    """
                    select requested_version, completed_version, last_status,
                           last_duration_ms, last_error, refresh_started_at,
                           refresh_completed_at, clock_timestamp()
                    from public.catalog_read_model_refresh_state
                    where singleton
                    """
                )
                row = cursor.fetchone()
                if row is None:
                    raise RuntimeError("Catalog refresh state row is missing")

                cursor.execute(
                    """
                    select c.relname, l.mode, l.granted
                    from pg_locks l
                    join pg_class c on c.oid = l.relation
                    join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public' and c.relname = any(%s)
                    order by c.relname, l.mode, l.granted
                    """,
                    (list(RELATIONS),),
                )
                locks = [
                    {"relation": relation, "mode": mode, "granted": granted}
                    for relation, mode, granted in cursor.fetchall()
                ]

                cursor.execute(
                    """
                    select exists (
                      select 1 from public.catalog_facets_cache
                      where filters = '{}'::jsonb
                    )
                    """
                )
                root_facets_cache_present = cursor.fetchone()[0]

                return {
                    "requested_version": row[0],
                    "completed_version": row[1],
                    "last_status": row[2],
                    "last_duration_ms": row[3],
                    "last_error": row[4],
                    "refresh_started_at": row[5].isoformat() if row[5] else None,
                    "refresh_completed_at": row[6].isoformat() if row[6] else None,
                    "checked_at_utc": row[7].isoformat(),
                    "locks": locks,
                    "refresh_lock_active": any(
                        lock["granted"] and lock["mode"] in REFRESH_LOCK_MODES
                        for lock in locks
                    ),
                    "root_facets_cache_present": root_facets_cache_present,
                }
            finally:
                cursor.execute("ROLLBACK")
    finally:
        connection.close()


def is_current(snapshot: dict) -> bool:
    return (
        snapshot["requested_version"] == snapshot["completed_version"]
        and snapshot["last_status"] in ("clean", "refreshed")
        and snapshot["last_error"] is None
        and not snapshot["refresh_lock_active"]
    )


def get_access_token() -> str:
    try:
        token = getpass.getpass(
            "Įvesk šviežią API access token (įvestis paslėpta; be „Bearer “): "
        ).strip()
    except (KeyboardInterrupt, EOFError):
        raise RuntimeError("Tokeno įvedimas atšauktas; API užklausos nesiųstos") from None
    if not token:
        raise RuntimeError("API matavimui reikia access token")
    if token.lower().startswith("bearer "):
        raise RuntimeError("Įvesk tik tokeno reikšmę, be „Bearer “ prefikso")
    return token


def safe_failure(status: int | None, exception: Exception | None = None) -> str | None:
    if exception is not None:
        return type(exception).__name__
    if status == 401:
        return "unauthorized"
    if status == 403:
        return "forbidden"
    if status is not None and status >= 500:
        return "http_server_error"
    if status is not None and status >= 400:
        return "http_client_error"
    if status is not None and status != 200:
        return "unexpected_http_status"
    return None


def request(host: str, path: str, token: str) -> dict:
    connection = http.client.HTTPSConnection(host, timeout=20)
    started_at = utc_now()
    started = time.perf_counter()
    try:
        connection.request(
            "GET",
            path,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
            },
        )
        response = connection.getresponse()
        body = response.read()
        elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
        response_headers = {
            name.lower(): value
            for name, value in response.getheaders()
            if name.lower() in {"cf-cache-status", "etag", "cache-control"}
        }
        return {
            "started_at_utc": started_at,
            "finished_at_utc": utc_now(),
            "elapsed_ms": elapsed_ms,
            "status": response.status,
            "response_bytes": len(body),
            "safe_error_summary": safe_failure(response.status),
            "response_headers": response_headers,
        }
    except Exception as exc:
        return {
            "started_at_utc": started_at,
            "finished_at_utc": utc_now(),
            "elapsed_ms": round((time.perf_counter() - started) * 1000, 2),
            "status": None,
            "response_bytes": 0,
            "safe_error_summary": safe_failure(None, exc),
            "response_headers": {},
        }
    finally:
        connection.close()


class JsonlLog:
    def __init__(self, path: Path):
        if path.exists():
            raise RuntimeError(f"Išvesties failas jau yra; pasirink naują: {path}")
        path.parent.mkdir(parents=True, exist_ok=True)
        self.handle = path.open("x", encoding="utf-8", newline="\n")

    def write(self, record: dict) -> None:
        self.handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
        self.handle.flush()

    def close(self) -> None:
        self.handle.close()


def record_request(log: JsonlLog, phase: str, endpoint: str, path: str, token: str) -> dict:
    before = database_snapshot()
    result = request(API_HOST, path, token)
    after = database_snapshot()
    record = {
        "type": "request",
        "phase": phase,
        "endpoint": endpoint,
        "path": path,
        "catalog_version_before": {
            "requested": before["requested_version"],
            "completed": before["completed_version"],
        },
        "catalog_version_after": {
            "requested": after["requested_version"],
            "completed": after["completed_version"],
        },
        "database_before": before,
        "http": result,
        "database_after": after,
        "refresh_lock_active_before": before["refresh_lock_active"],
        "refresh_lock_active_after": after["refresh_lock_active"],
        "refresh_version_pending_before": before["requested_version"] != before["completed_version"],
        "refresh_version_pending_after": after["requested_version"] != after["completed_version"],
        "overlapped_refresh_lock": before["refresh_lock_active"] or after["refresh_lock_active"],
    }
    log.write(record)
    return record


def record_pair(log: JsonlLog, phase: str, token: str) -> list[dict]:
    return [
        record_request(log, phase, endpoint, path, token)
        for endpoint, path in ENDPOINTS
    ]


def wait_for_initial_stable(log: JsonlLog, timeout_seconds: int, poll_seconds: float) -> dict:
    deadline = time.monotonic() + timeout_seconds
    last_notice = 0.0
    while True:
        snapshot = database_snapshot()
        if is_current(snapshot):
            log.write({"type": "state", "phase": "initial_stable", "database": snapshot})
            return snapshot
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Pradinė katalogo būsena netapo stabili per {timeout_seconds} s")
        if time.monotonic() - last_notice >= 30:
            print(
                "Laukiu dabartinio refresh pabaigos prieš pradinį matavimą "
                f"({snapshot['completed_version']} -> {snapshot['requested_version']}, "
                f"{snapshot['last_status']})...",
                flush=True,
            )
            last_notice = time.monotonic()
        time.sleep(poll_seconds)


def wait_for_active_cycle(
    log: JsonlLog, baseline: dict, timeout_seconds: int, poll_seconds: float
) -> dict | None:
    deadline = time.monotonic() + timeout_seconds
    last_notice = 0.0
    while time.monotonic() < deadline:
        snapshot = database_snapshot()
        if snapshot["requested_version"] > snapshot["completed_version"] and snapshot["refresh_lock_active"]:
            log.write({"type": "state", "phase": "active_refresh_detected", "database": snapshot})
            return snapshot
        if (
            snapshot["refresh_completed_at"] != baseline["refresh_completed_at"]
            and snapshot["last_status"] in ("refreshed", "failed")
        ):
            log.write(
                {
                    "type": "state",
                    "phase": "refresh_window_missed_before_lock_observed",
                    "database": snapshot,
                }
            )
            return None
        if time.monotonic() - last_notice >= 60:
            print(
                "Laukiu natūralaus refresh; bandymo metu jo nepaleidžiu "
                f"(versijos {snapshot['completed_version']} -> {snapshot['requested_version']})...",
                flush=True,
            )
            last_notice = time.monotonic()
        time.sleep(poll_seconds)
    return None


def wait_for_cycle_end(
    log: JsonlLog, active: dict, timeout_seconds: int, poll_seconds: float
) -> dict | None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        snapshot = database_snapshot()
        completed_at_changed = snapshot["refresh_completed_at"] != active["refresh_completed_at"]
        settled = (
            completed_at_changed
            and snapshot["last_status"] in ("refreshed", "failed")
            and not snapshot["refresh_lock_active"]
        )
        if settled:
            log.write({"type": "state", "phase": "refresh_settled", "database": snapshot})
            return snapshot
        time.sleep(poll_seconds)
    snapshot = database_snapshot()
    log.write({"type": "state", "phase": "refresh_completion_timeout", "database": snapshot})
    return None


def validate_api_base(api_base: str) -> str:
    parsed = urlparse(api_base)
    if (
        parsed.scheme != "https"
        or parsed.hostname != API_HOST
        or parsed.username
        or parsed.password
        or parsed.path not in ("", "/")
        or parsed.port not in (None, 443)
    ):
        raise ValueError("API hostas turi būti patvirtintas HTTPS katalogo API origin")
    return parsed.hostname


def run(args: argparse.Namespace) -> int:
    host = validate_api_base(args.api_base)
    if args.output.exists():
        raise RuntimeError(f"Išvesties failas jau yra; pasirink naują: {args.output}")
    token = get_access_token()
    log = JsonlLog(args.output)
    started_at = utc_now()
    try:
        log.write(
            {
                "type": "run",
                "started_at_utc": started_at,
                "api_origin": args.api_base,
                "endpoints": [path for _, path in ENDPOINTS],
                "poll_interval_seconds": args.poll_interval_seconds,
                "max_wait_for_refresh_minutes": args.max_wait_minutes,
                "completion_timeout_seconds": args.completion_timeout_seconds,
                "refresh_was_triggered_by_probe": False,
                "response_bodies_or_auth_headers_logged": False,
            }
        )
        print("Tikrinama pradinė stabili katalogo būsena...", flush=True)
        baseline = wait_for_initial_stable(
            log, args.initial_stable_timeout_seconds, args.poll_interval_seconds
        )
        preflight = record_pair(log, "before_refresh", token)
        auth_failure = any(item["http"]["status"] in (401, 403) for item in preflight)
        if auth_failure:
            log.write(
                {
                    "type": "outcome",
                    "finished_at_utc": utc_now(),
                    "result": "authentication_failed_before_wait",
                    "refresh_window_captured": False,
                }
            )
            print("API autentifikacija grąžino 401/403; refresh laukimo bandymas sustabdytas.", flush=True)
            return 2

        print(
            f"Pradinės užklausos išsiųstos. Laukiu vieno natūralaus refresh iki "
            f"{args.max_wait_minutes} min.; refresh inicijuojamas nebus.",
            flush=True,
        )
        active = wait_for_active_cycle(
            log, baseline, args.max_wait_minutes * 60, args.poll_interval_seconds
        )
        if active is None:
            # A completed cycle can be detected between polls. The current
            # state still gets a single post-cycle measurement, clearly marked.
            after = database_snapshot()
            cycle_ended = (
                after["refresh_completed_at"] != baseline["refresh_completed_at"]
                and after["last_status"] in ("refreshed", "failed")
            )
            if cycle_ended and not after["refresh_lock_active"]:
                record_pair(log, "after_refresh_without_active_sample", token)
                outcome = "refresh_window_missed_but_post_sampled"
            else:
                outcome = "no_refresh_observed_within_wait_limit"
            log.write(
                {
                    "type": "outcome",
                    "finished_at_utc": utc_now(),
                    "result": outcome,
                    "refresh_window_captured": False,
                    "database_final": after,
                }
            )
            print(f"Bandymo rezultatas: {outcome}.", flush=True)
            return 0 if cycle_ended else 3

        active_requests = record_pair(log, "during_refresh", token)
        active_capture = all(item["overlapped_refresh_lock"] for item in active_requests)
        settled = wait_for_cycle_end(
            log, active, args.completion_timeout_seconds, args.poll_interval_seconds
        )
        if settled is not None:
            after_requests = record_pair(log, "after_refresh", token)
        else:
            after_requests = []
        success_statuses = all(
            item["http"]["status"] == 200
            for item in preflight + active_requests + after_requests
        )
        within_target = all(
            item["http"]["elapsed_ms"] <= args.slow_threshold_ms
            for item in preflight + active_requests + after_requests
        )
        if settled is None:
            outcome = "refresh_did_not_settle_within_timeout"
        elif not active_capture:
            outcome = "active_refresh_lock_not_confirmed_for_both_endpoints"
        elif not success_statuses:
            outcome = "one_or_more_api_requests_failed"
        elif not within_target:
            outcome = "api_success_with_request_over_8s_threshold"
        else:
            outcome = "captured_refresh_cycle_all_requests_200_under_threshold"
        log.write(
            {
                "type": "outcome",
                "finished_at_utc": utc_now(),
                "result": outcome,
                "refresh_window_captured": active_capture,
                "all_http_200": success_statuses,
                "all_requests_within_threshold": within_target,
                "slow_threshold_ms": args.slow_threshold_ms,
                "refresh_state_after": settled,
            }
        )
        print(f"Bandymo rezultatas: {outcome}.", flush=True)
        return 0 if outcome == "captured_refresh_cycle_all_requests_200_under_threshold" else 1
    except Exception as exc:
        log.write(
            {
                "type": "probe_error",
                "at_utc": utc_now(),
                "safe_error_summary": safe_failure(None, exc),
            }
        )
        raise
    finally:
        log.close()
        token = ""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--api-base",
        default=API_ORIGIN,
        help="Patvirtintas katalogo API origin (kitas hostas neleidžiamas)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("docs/katalogo-filtravimas/API_REFRESH_PROBE_2026-10-05.jsonl"),
    )
    parser.add_argument("--max-wait-minutes", type=int, default=30)
    parser.add_argument("--initial-stable-timeout-seconds", type=int, default=360)
    parser.add_argument("--completion-timeout-seconds", type=int, default=360)
    parser.add_argument("--poll-interval-seconds", type=float, default=5.0)
    parser.add_argument("--slow-threshold-ms", type=int, default=8000)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    if args.max_wait_minutes < 1 or args.initial_stable_timeout_seconds < 1:
        parser.error("Laukimo ribos turi būti teigiamos")
    if args.completion_timeout_seconds < 1 or args.poll_interval_seconds <= 0:
        parser.error("Ciklo pabaigos timeout ir poll intervalas turi būti teigiami")
    if args.slow_threshold_ms < 1:
        parser.error("Lėto atsakymo riba turi būti teigiama")
    try:
        exit_code = run(args)
    except (RuntimeError, ValueError, psycopg.Error) as exc:
        print(f"Refresh probe nepavyko: {exc}", file=sys.stderr)
        exit_code = 2
    raise SystemExit(exit_code)


if __name__ == "__main__":
    main()
