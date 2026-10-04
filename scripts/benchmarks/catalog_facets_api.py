"""Repeatable, paced catalog facet API benchmark.

Generate a fixed scenario manifest from the read-only PostgreSQL tunnel, then
run authenticated HTTP miss/hit pairs. The bearer token is read from
CATALOG_BENCH_TOKEN or a hidden interactive prompt and is never written to
the output.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import getpass
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import statistics
import sys
import time
from urllib.parse import quote, urlencode, urlparse

import psycopg


GROUPS = ("single", "category_color", "multi_group", "sizes", "price_lpl", "narrow")
ALLOWED_API_HOSTS = {"aboutyou-private-catalog-api.aurimas-zvirb.workers.dev"}
ARRAY_FIELDS = (
    "brands", "brandTiers", "sources", "categories", "colors", "colorShades",
    "sizes", "otherSizes", "materials", "patterns", "features", "styles", "productTypes",
)
BOOL_FIELDS = ("isPremium", "excludeBasics", "excludeAccessories", "belowObserved30d", "newOnly")
PARAM_FIELDS = {
    "brands": "brands", "color_shades": "colorShades", "sizes": "sizes",
    "other_sizes": "otherSizes", "category": "categoryPath",
    "price_min": "priceMin", "price_max": "priceMax", "discount_min": "discountMin",
    "lpl_proximity_pct": "lplProximityPct", "below_observed_30d": "belowObserved30d",
    "price_comparison": "priceComparison",
}


def db_connection():
    # libpq reads the user's pgpass.conf; never pass or print a password.
    return psycopg.connect(
        "host=127.0.0.1 port=15432 dbname=postgres user=codex_reader "
        "options=-cstatement_timeout=15000",
        connect_timeout=5,
    )


def read_only_query(sql: str, parameters=()):
    connection = db_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute("BEGIN READ ONLY")
            try:
                cursor.execute(sql, parameters)
                return cursor.fetchall()
            finally:
                cursor.execute("ROLLBACK")
    finally:
        connection.close()


def cache_filters(params: dict) -> dict:
    result = {key: [] for key in ARRAY_FIELDS}
    result.update({key: False for key in BOOL_FIELDS})
    result["priceComparison"] = "observed"
    for query_key, value in params.items():
        field = PARAM_FIELDS[query_key]
        result[field] = value if isinstance(value, list) else value
        if query_key == "category":
            result["categories"] = [value]
    if not params:
        return {}
    return result


def query_string(params: dict) -> str:
    values = {}
    for key, value in params.items():
        if isinstance(value, list):
            # The app encodes each size before joining the comma-separated list.
            values[key] = ",".join(quote(item, safe="") for item in value) if key in ("sizes", "other_sizes") else ",".join(value)
        elif isinstance(value, bool):
            values[key] = str(value).lower()
        else:
            values[key] = str(value)
    return urlencode(values)


def percentile(values: list[float], percentage: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = (len(ordered) - 1) * percentage
    lower = math.floor(rank)
    upper = math.ceil(rank)
    return round(ordered[lower] + (ordered[upper] - ordered[lower]) * (rank - lower), 2)


def catalog_version() -> dict:
    rows = read_only_query(
        "select completed_version, requested_version, updated_at "
        "from public.catalog_read_model_refresh_state limit 1"
    )
    if not rows:
        raise RuntimeError("Catalog refresh state is missing")
    completed, requested, updated_at = rows[0]
    return {"completed": completed, "requested": requested, "updated_at": updated_at.isoformat()}


def generate(path: Path) -> None:
    version_before = catalog_version()
    if version_before["completed"] != version_before["requested"]:
        raise RuntimeError(f"Catalog refresh is pending: {version_before}")
    rows = read_only_query("""
        select i.brand, i.color_shade, i.category_paths, i.current_price,
               i.source_lpl_30, i.below_source_lpl_30d, i.discount_pct,
               i.other_sizes, s.token
        from (
          select id, brand, color_shade, category_paths, current_price,
                 source_lpl_30, below_source_lpl_30d, discount_pct, other_sizes
          from public.catalog_items_read
          order by md5(id::text)
          limit 12000
        ) i
        left join lateral (
          select token from public.catalog_effective_size_membership_read
          where product_id = i.id order by token limit 1
        ) s on true
    """)
    products = []
    for brand, shade, paths, price, lpl, below, discount, other_sizes, size in rows:
        leaves = [path for path in (paths or []) if path.count(">") >= 2]
        category = max(leaves, key=lambda item: (item.count(">"), len(item))) if leaves else None
        products.append(dict(brand=brand, shade=shade, category=category,
                             price=price, lpl=lpl, below=below, discount=discount,
                             other_sizes=other_sizes or [], size=size))

    scenarios = []
    seen = set()

    counts = Counter()

    def add(group: str, params: dict, limit: int = 40) -> None:
        if counts[group] >= limit:
            return
        key = json.dumps(cache_filters(params), ensure_ascii=False, sort_keys=True)
        if key in seen:
            return
        seen.add(key)
        counts[group] += 1
        scenarios.append({"id": f"{group}-{counts[group]:02d}",
                          "group": group, "params": params, "query": query_string(params),
                          "cache_filters": cache_filters(params)})

    shades = [value for value, _ in Counter(p["shade"] for p in products if p["shade"] and p["shade"] != "other").most_common(12)]
    brands = [value for value, _ in Counter(p["brand"] for p in products if p["brand"]).most_common(14)]
    categories = [value for value, _ in Counter(p["category"] for p in products if p["category"]).most_common(14)]
    for shade in shades:
        add("single", {"color_shades": [shade]})
    for brand in brands:
        add("single", {"brands": [brand]})
    for category in categories:
        add("single", {"category": category})

    for p in products:
        if p["category"] and p["shade"] and p["shade"] != "other":
            add("category_color", {"category": p["category"], "color_shades": [p["shade"]]})
        if p["brand"] and p["category"] and p["shade"] and p["shade"] != "other":
            add("multi_group", {"brands": [p["brand"]], "category": p["category"], "color_shades": [p["shade"]]})
        if p["brand"] and p["category"] and p["shade"] and p["size"]:
            add("narrow", {"brands": [p["brand"]], "category": p["category"],
                           "color_shades": [p["shade"]], "sizes": [p["size"]]})

    for p in products:
        if p["size"] and p["shade"] and p["shade"] != "other":
            add("sizes", {"sizes": [p["size"]], "color_shades": [p["shade"]]}, limit=20)
    for p in products:
        if p["other_sizes"] and p["category"]:
            add("sizes", {"other_sizes": [p["other_sizes"][0]], "category": p["category"]})

    for p in products:
        if p["below"] and p["shade"] and p["shade"] != "other":
            add("price_lpl", {"below_observed_30d": True, "price_comparison": "source_lpl", "color_shades": [p["shade"]]}, limit=10)
    for p in products:
        if p["lpl"] and p["lpl"] > 0 and p["price"] * 100 / p["lpl"] <= 105 and p["category"]:
            add("price_lpl", {"lpl_proximity_pct": 5, "category": p["category"]}, limit=20)
    for p in products:
        if p["price"] and p["shade"] and p["shade"] != "other":
            lower = max(0, int(p["price"] * 0.8 // 100 * 100))
            upper = int(math.ceil(p["price"] * 1.2 / 100) * 100)
            add("price_lpl", {"price_min": lower, "price_max": upper, "color_shades": [p["shade"]]}, limit=30)
    for p in products:
        if p["discount"] and p["discount"] >= 10 and p["category"]:
            add("price_lpl", {"discount_min": 10, "category": p["category"]})

    if any(counts[group] < 40 for group in GROUPS):
        raise RuntimeError(f"Not enough witnessed scenarios: {dict(counts)}")
    buckets = {group: [item for item in scenarios if item["group"] == group] for group in GROUPS}
    sizes = buckets["sizes"]
    buckets["sizes"] = [item for pair in zip(sizes[:20], sizes[20:]) for item in pair]
    price = buckets["price_lpl"]
    buckets["price_lpl"] = [item for quartet in zip(price[:10], price[10:20], price[20:30], price[30:]) for item in quartet]
    scenarios = [buckets[group][index] for index in range(40) for group in GROUPS]
    version_after = catalog_version()
    if (version_after["completed"] != version_before["completed"]
            or version_after["requested"] != version_after["completed"]):
        raise RuntimeError(f"Catalog version changed while generating scenarios: {version_before} -> {version_after}")
    manifest = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "catalog_version_at_generation": version_after,
        "source": "VPS catalog_items_read + catalog_effective_size_membership_read; 12000 deterministic product samples",
        "groups": list(GROUPS),
        "scenarios": scenarios,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Saved {len(scenarios)} candidates to {path}; {dict(counts)}")


def cache_created_at(filters: dict) -> str | None:
    rows = read_only_query(
        "select created_at from public.catalog_facets_cache where filters = %s::jsonb",
        (json.dumps(filters, ensure_ascii=False),),
    )
    return rows[0][0].isoformat() if rows else None


def request(host: str, path: str, token: str) -> dict:
    connection = http.client.HTTPSConnection(host, timeout=20)
    started = time.perf_counter()
    try:
        connection.request("GET", path, headers={"Authorization": f"Bearer {token}", "Accept": "application/json", "Cache-Control": "no-store"})
        response = connection.getresponse()
        body = response.read()
        elapsed = round((time.perf_counter() - started) * 1000, 2)
        return {"elapsed_ms": elapsed, "status": response.status, "bytes": len(body),
                "body_sha256": hashlib.sha256(body).hexdigest(),
                "error": None if response.status == 200 else body[:300].decode("utf-8", "replace")}
    except Exception as exc:
        return {"elapsed_ms": round((time.perf_counter() - started) * 1000, 2),
                "status": None, "bytes": 0, "body_sha256": None, "error": type(exc).__name__}
    finally:
        connection.close()


def run(manifest_path: Path, api_base: str, output_path: Path, per_group: int) -> None:
    parsed = urlparse(api_base)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.path not in ("", "/") or parsed.port not in (None, 443):
        raise ValueError("--api-base must be an HTTPS origin with no path or credentials")
    if parsed.hostname not in ALLOWED_API_HOSTS:
        raise ValueError("--api-base is not the project's confirmed production API host")
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    version_before = catalog_version()
    if version_before["completed"] != version_before["requested"]:
        raise RuntimeError(f"Catalog refresh is pending; benchmark not started: {version_before}")
    manifest_version = manifest.get("catalog_version_at_generation", {})
    if manifest_version.get("completed") != version_before["completed"] or manifest_version.get("requested") != manifest_version.get("completed"):
        raise RuntimeError("Manifest was generated from another or pending catalog version; regenerate it before benchmarking")
    token = os.environ.get("CATALOG_BENCH_TOKEN", "").strip()
    if not token:
        if not sys.stdin.isatty():
            raise RuntimeError("CATALOG_BENCH_TOKEN is missing and no interactive terminal is available")
        token = getpass.getpass("Paste the signed-in API access token (hidden input): ").strip()
    if not token:
        raise RuntimeError("An API access token is required; never put it in a command argument or repository file")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    counts = Counter()
    measurements = []
    failures = 0
    aborted_reason = None
    started_at = datetime.now(timezone.utc).isoformat()
    with output_path.open("x", encoding="utf-8") as output:
        meta = {"type": "run", "started_at_utc": started_at, "api_origin": api_base,
                "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(), "per_group": per_group,
                "catalog_version_before": version_before}
        output.write(json.dumps(meta, ensure_ascii=False) + "\n")
        output.flush()
        for item in manifest["scenarios"]:
            group = item["group"]
            if counts[group] >= per_group:
                continue
            filters = item["cache_filters"]
            before = cache_created_at(filters)
            if before is not None:
                continue  # A real DB miss requires an absent normalized key.
            path = "/v1/catalog/facets?" + item["query"]
            miss = request(parsed.netloc, path, token)
            after_miss = cache_created_at(filters)
            hit = request(parsed.netloc, path, token) if miss["status"] == 200 and after_miss else None
            after_hit = cache_created_at(filters) if hit else None
            valid_pair = bool(miss["status"] == 200 and hit and hit["status"] == 200 and after_miss and after_hit == after_miss)
            record = {"type": "scenario", "at_utc": datetime.now(timezone.utc).isoformat(),
                      "id": item["id"], "group": group, "params": item["params"],
                      "cache_before": before, "cache_after_miss": after_miss,
                      "cache_after_hit": after_hit, "miss": miss, "hit": hit,
                      "valid_pair": valid_pair}
            output.write(json.dumps(record, ensure_ascii=False) + "\n")
            output.flush()
            measurements.append(record)
            counts[group] += 1
            current_version = catalog_version()
            if current_version["completed"] != version_before["completed"] or current_version["requested"] != current_version["completed"]:
                aborted_reason = f"Catalog version changed or refresh began: {current_version}"
                break
            if not valid_pair:
                failures += 1
                if failures >= 2:
                    aborted_reason = "Two failed cache miss/hit pairs"
                    break
            time.sleep(0.2)
        valid = [item for item in measurements if item["valid_pair"]]
        misses = [item["miss"]["elapsed_ms"] for item in valid]
        hits = [item["hit"]["elapsed_ms"] for item in valid]
        summary = {"type": "summary", "finished_at_utc": datetime.now(timezone.utc).isoformat(),
                   "attempted": len(measurements), "valid_pairs": len(valid), "failures": failures,
                   "aborted_reason": aborted_reason, "catalog_version_after": catalog_version(),
                   "per_group_attempted": dict(counts),
                   "status_counts": dict(Counter(str(item[phase]["status"]) for item in measurements for phase in ("miss", "hit") if item[phase])),
                   "timeout_count": sum(item[phase]["error"] in ("TimeoutError", "socket.timeout") for item in measurements for phase in ("miss", "hit") if item[phase]),
                   "miss_p50_ms": percentile(misses, 0.5), "miss_p95_ms": percentile(misses, 0.95),
                   "hit_p50_ms": percentile(hits, 0.5), "hit_p95_ms": percentile(hits, 0.95),
                   "groups": {group: {"n": sum(item["group"] == group for item in valid),
                                      "miss_median_ms": statistics.median([item["miss"]["elapsed_ms"] for item in valid if item["group"] == group]) if any(item["group"] == group for item in valid) else None,
                                      "miss_max_ms": max((item["miss"]["elapsed_ms"] for item in valid if item["group"] == group), default=None)} for group in GROUPS}}
        output.write(json.dumps(summary, ensure_ascii=False) + "\n")
        output.flush()
    print(json.dumps(summary, ensure_ascii=False, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    make = sub.add_parser("generate", help="Generate deterministic DB-witnessed scenarios in read-only mode")
    make.add_argument("--output", type=Path, required=True)
    measure = sub.add_parser("run", help="Measure authenticated API miss/hit pairs")
    measure.add_argument("--manifest", type=Path, required=True)
    measure.add_argument("--api-base", required=True)
    measure.add_argument("--output", type=Path, required=True)
    measure.add_argument("--per-group", type=int, choices=(2, 20), default=2)
    args = parser.parse_args()
    try:
        if args.command == "generate":
            generate(args.output)
        else:
            run(args.manifest, args.api_base, args.output, args.per_group)
    except (RuntimeError, ValueError) as exc:
        print(f"Benchmark not started: {exc}", file=sys.stderr)
        raise SystemExit(2) from None


if __name__ == "__main__":
    main()
