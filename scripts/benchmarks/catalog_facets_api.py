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


def wait_for_current_catalog(deadline: float) -> dict:
    last_notice = 0.0
    while True:
        version = catalog_version()
        if version["completed"] == version["requested"]:
            return version
        now = time.monotonic()
        if now >= deadline:
            raise RuntimeError(f"Catalog did not become current within 15 minutes: {version}")
        if now - last_notice >= 30:
            print(f"Catalog refresh pending ({version['completed']} -> {version['requested']}); waiting automatically...", flush=True)
            last_notice = now
        time.sleep(min(10, deadline - now))


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


def prior_valid_filters(paths: list[Path], api_base: str) -> tuple[dict[str, set[str]], list[int]]:
    """Load verified miss/hit keys from earlier segments, across catalog versions."""
    keys = {group: set() for group in GROUPS}
    owners = {}
    versions = set()
    visited = set()
    visiting = set()

    def include(path: Path) -> None:
        resolved = path.resolve()
        if resolved in visited:
            return
        if resolved in visiting:
            raise ValueError(f"Circular --resume-from chain: {path}")
        visiting.add(resolved)
        try:
            load(path)
        finally:
            visiting.remove(resolved)
        visited.add(resolved)

    def load(path: Path) -> None:
        rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
        if len(rows) < 2 or rows[0].get("type") != "run" or rows[-1].get("type") != "summary":
            raise ValueError(f"Incomplete prior benchmark: {path}")
        meta = rows[0]
        if meta.get("api_origin") != api_base:
            raise ValueError(f"Prior benchmark uses another API origin: {path}")
        for ancestor_name in meta.get("resume_from", []):
            ancestor = Path(ancestor_name)
            if not ancestor.is_absolute() and not ancestor.exists():
                ancestor = path.parent / ancestor.name
            include(ancestor)
        manifest_path = path.with_suffix(".manifest.json")
        manifest_bytes = manifest_path.read_bytes()
        if hashlib.sha256(manifest_bytes).hexdigest() != meta.get("manifest_sha256"):
            raise ValueError(f"Prior manifest SHA-256 mismatch: {manifest_path}")
        manifest = json.loads(manifest_bytes)
        scenarios = {item["id"]: item for item in manifest["scenarios"]}
        for row in rows[1:-1]:
            if row.get("type") != "scenario" or not row.get("valid_pair"):
                continue
            item = scenarios.get(row.get("id"))
            before = row.get("catalog_version_before", {})
            after = row.get("catalog_version_after", {})
            miss, hit = row.get("miss") or {}, row.get("hit") or {}
            if (item is None or item["group"] != row.get("group")
                    or miss.get("status") != 200 or hit.get("status") != 200
                    or miss.get("body_sha256") != hit.get("body_sha256")
                    or row.get("cache_before") is not None
                    or not row.get("cache_after_miss")
                    or row.get("cache_after_miss") != row.get("cache_after_hit")
                    or before.get("completed") != after.get("completed")
                    or before.get("requested") != before.get("completed")
                    or after.get("requested") != after.get("completed")):
                raise ValueError(f"Invalid prior pair {row.get('id')}: {path}")
            key = json.dumps(item["cache_filters"], ensure_ascii=False, sort_keys=True)
            owner = owners.setdefault(key, item["group"])
            if owner != item["group"]:
                raise ValueError(f"Prior filter key appears in different groups: {path}")
            keys[owner].add(key)
            versions.add(before["completed"])

    for path in paths:
        include(path)
    return keys, sorted(versions)


def access_token() -> str:
    token = os.environ.get("CATALOG_BENCH_TOKEN", "").strip()
    if not token:
        if not sys.stdin.isatty():
            raise RuntimeError("CATALOG_BENCH_TOKEN is missing and no interactive terminal is available")
        try:
            token = getpass.getpass("Paste a fresh API access token, then press Enter (input is hidden): ").strip()
        except (KeyboardInterrupt, EOFError):
            raise RuntimeError("Token entry canceled; no API request was sent") from None
    if not token:
        raise RuntimeError("An API access token is required; never put it in a command argument or repository file")
    if token.lower().startswith("bearer "):
        raise RuntimeError("Paste only the token value, without the Bearer prefix")
    return token


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


def run(manifest_path: Path | None, api_base: str, output_path: Path,
        per_group: int, auto_manifest: bool = False, start_index: int = 0,
        resume_from: list[Path] | None = None) -> None:
    parsed = urlparse(api_base)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.path not in ("", "/") or parsed.port not in (None, 443):
        raise ValueError("--api-base must be an HTTPS origin with no path or credentials")
    if parsed.hostname not in ALLOWED_API_HOSTS:
        raise ValueError("--api-base is not the project's confirmed production API host")
    if output_path.exists():
        raise RuntimeError(f"Output already exists; choose a new --output path: {output_path}")
    resume_from = resume_from or []
    prior_keys, prior_versions = prior_valid_filters(resume_from, api_base)
    prior_counts = {group: len(prior_keys[group]) for group in GROUPS}
    prior_all_keys = set().union(*prior_keys.values())
    if auto_manifest:
        if manifest_path is not None:
            raise ValueError("--auto-manifest cannot be combined with --manifest")
        manifest_path = output_path.with_suffix(".manifest.json")
        if manifest_path.exists():
            raise RuntimeError(f"Manifest already exists; choose a new --output path: {manifest_path}")
        token = access_token()
        deadline = time.monotonic() + 15 * 60
        while True:
            wait_for_current_catalog(deadline)
            try:
                generate(manifest_path)
            except RuntimeError as exc:
                if "Catalog refresh is pending" not in str(exc) and "Catalog version changed while generating" not in str(exc):
                    raise
                if time.monotonic() >= deadline:
                    raise RuntimeError("Catalog did not stay current long enough to generate a manifest") from None
                continue
            manifest_bytes = manifest_path.read_bytes()
            manifest = json.loads(manifest_bytes)
            version_before = catalog_version()
            manifest_version = manifest.get("catalog_version_at_generation", {})
            if (version_before["completed"] == version_before["requested"]
                    and manifest_version.get("completed") == version_before["completed"]):
                break
            print("Catalog version changed before measuring; waiting for the next current version...", flush=True)
            if time.monotonic() >= deadline:
                raise RuntimeError("Catalog did not stay current long enough to start the benchmark")
    else:
        if manifest_path is None:
            raise ValueError("--manifest is required unless --auto-manifest is used")
        token = ""
        manifest_bytes = manifest_path.read_bytes()
        manifest = json.loads(manifest_bytes)
        version_before = catalog_version()
        if version_before["completed"] != version_before["requested"]:
            raise RuntimeError(f"Catalog refresh is pending; benchmark not started: {version_before}")
        manifest_version = manifest.get("catalog_version_at_generation", {})
        if manifest_version.get("completed") != version_before["completed"] or manifest_version.get("requested") != manifest_version.get("completed"):
            raise RuntimeError("Manifest was generated from another or pending catalog version; regenerate it before benchmarking")
    assert manifest_path is not None
    if not token:
        token = access_token()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    counts = Counter()
    valid_counts = Counter()
    candidate_indices = Counter()
    measurements = []
    failures = 0
    aborted_reason = None
    started_at = datetime.now(timezone.utc).isoformat()
    with output_path.open("x", encoding="utf-8") as output:
        meta = {"type": "run", "started_at_utc": started_at, "api_origin": api_base,
                "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(), "per_group": per_group,
                "start_index_per_group": start_index,
                "resume_from": [str(path) for path in resume_from],
                "prior_valid_pairs": sum(prior_counts.values()),
                "prior_catalog_versions": prior_versions,
                "catalog_version_before": version_before}
        output.write(json.dumps(meta, ensure_ascii=False) + "\n")
        output.flush()
        for item in manifest["scenarios"]:
            group = item["group"]
            candidate_index = candidate_indices[group]
            candidate_indices[group] += 1
            if candidate_index < start_index:
                continue
            if prior_counts[group] + valid_counts[group] >= per_group:
                continue
            filters = item["cache_filters"]
            key = json.dumps(filters, ensure_ascii=False, sort_keys=True)
            if key in prior_all_keys:
                continue
            pair_version_before = catalog_version()
            if (pair_version_before["completed"] != version_before["completed"]
                    or pair_version_before["requested"] != pair_version_before["completed"]):
                aborted_reason = f"Catalog version changed or refresh began before pair: {pair_version_before}"
                break
            before = cache_created_at(filters)
            if before is not None:
                continue  # A real DB miss requires an absent normalized key.
            path = "/v1/catalog/facets?" + item["query"]
            miss = request(parsed.netloc, path, token)
            after_miss = cache_created_at(filters)
            hit = request(parsed.netloc, path, token) if miss["status"] == 200 and after_miss else None
            after_hit = cache_created_at(filters) if hit else None
            pair_version_after = catalog_version()
            stable_version = (pair_version_after["completed"] == pair_version_before["completed"]
                              and pair_version_after["requested"] == pair_version_after["completed"])
            valid_pair = bool(stable_version and miss["status"] == 200 and hit and hit["status"] == 200
                              and after_miss and after_hit == after_miss)
            record = {"type": "scenario", "at_utc": datetime.now(timezone.utc).isoformat(),
                      "id": item["id"], "group": group, "params": item["params"],
                      "candidate_index_per_group": candidate_index,
                      "catalog_version_before": pair_version_before,
                      "catalog_version_after": pair_version_after,
                      "cache_before": before, "cache_after_miss": after_miss,
                      "cache_after_hit": after_hit, "miss": miss, "hit": hit,
                      "valid_pair": valid_pair}
            output.write(json.dumps(record, ensure_ascii=False) + "\n")
            output.flush()
            measurements.append(record)
            counts[group] += 1
            if valid_pair:
                valid_counts[group] += 1
            if not stable_version:
                aborted_reason = f"Catalog version changed or refresh began during pair: {pair_version_after}"
                break
            auth_status = miss["status"] if miss["status"] in (401, 403) else hit["status"] if hit and hit["status"] in (401, 403) else None
            if auth_status is not None:
                failures += 1
                aborted_reason = ("HTTP 401: signed-in session is invalid or expired; use a fresh access token"
                                  if auth_status == 401 else "HTTP 403: signed-in user lacks access to the API")
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
                    "prior_valid_pairs": sum(prior_counts.values()),
                    "cumulative_valid_pairs": sum(prior_counts.values()) + len(valid),
                    "per_group_cumulative_valid": {group: prior_counts[group] + valid_counts[group] for group in GROUPS},
                    "target_per_group": per_group,
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
    measure.add_argument("--manifest", type=Path)
    measure.add_argument("--auto-manifest", action="store_true",
                         help="Generate a fresh manifest beside --output immediately before measuring")
    measure.add_argument("--api-base", required=True)
    measure.add_argument("--output", type=Path, required=True)
    measure.add_argument("--per-group", type=int, choices=(1, 2, 20), default=1)
    measure.add_argument("--start-index", type=int, choices=range(40), default=0,
                         help="Skip this many candidates in each group for a later measurement segment")
    measure.add_argument("--resume-from", type=Path, action="append", default=[],
                         help="Prior JSONL segment to exclude by normalized filter key; repeat for multiple segments")
    args = parser.parse_args()
    try:
        if args.command == "generate":
            generate(args.output)
        else:
            run(args.manifest, args.api_base, args.output, args.per_group,
                args.auto_manifest, args.start_index, args.resume_from)
    except (RuntimeError, ValueError) as exc:
        print(f"Benchmark not started: {exc}", file=sys.stderr)
        raise SystemExit(2) from None


if __name__ == "__main__":
    main()
