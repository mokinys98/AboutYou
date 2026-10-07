# VPS monitoring stack

This Compose project runs Prometheus, Grafana, Node Exporter, and PostgreSQL Exporter separately from the Supabase Compose project.

## Defaults

- Prometheus retains up to 3 days of metrics, with an additional 2 GB storage cap.
- Grafana is published only on host loopback at `127.0.0.1:3001`; Prometheus is published only at `127.0.0.1:9090`.
- Node Exporter has no published host port. Prometheus reaches it over the private Compose network.
- PostgreSQL Exporter has no published host port. It joins the private monitoring network and the existing Supabase Docker network to read PostgreSQL statistics.
- PostgreSQL Exporter uses a dedicated `supabase_metrics` login with `pg_monitor`, a maximum of five connections, and no application-table grants. Its PostgreSQL connection explicitly sets `search_path` to `extensions,pg_catalog` so the `pg_stat_statements` function resolves from Supabase's `extensions` schema.
- Prometheus scrapes PostgreSQL metrics every 30 seconds, including `pg_stat_statements` summaries without query text, long-running transactions, checkpointer, and database wraparound statistics.
- Prometheus and Grafana data use named Docker volumes. They are not part of the current Supabase backup script; if lost, metrics history and dashboards must be recreated.

## Deploy on the VPS

Copy this directory to `/srv/monitoring`, create a root-only `.env` file containing a unique Grafana administrator password, then review `compose.yaml` and `prometheus.yml` before starting the project. `.env.example` is a template; replace its password before use:

```dotenv
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=<unique-random-password>
SUPABASE_DOCKER_NETWORK=<existing-Supabase-Docker-network>
POSTGRES_EXPORTER_USER=supabase_metrics
POSTGRES_EXPORTER_PASSWORD=<separate-random-password>
```

Use a random password with only letters and digits so Compose environment interpolation cannot alter it. Set `.env` permissions to `0600`. Start the project from `/srv/monitoring` with `docker compose -f compose.yaml up -d` only after confirming the Docker daemon is healthy.

The `supabase` network is external. Set `SUPABASE_DOCKER_NETWORK` to the actual Docker network used by the running Supabase `db` container. Do not create a new network for this value: the exporter must share the existing database network.

The Node Exporter network collectors are disabled because it runs in an isolated container network; the initial dashboard focuses on host CPU, memory, filesystem, and disk I/O rather than reporting the exporter's own container network as host traffic.

## Private access

Keep the published ports bound to `127.0.0.1`. In the SSH client, forward local port `3001` to remote `127.0.0.1:3001` to use Grafana at `http://127.0.0.1:3001`. To inspect Prometheus directly, also forward local port `9090` to remote `127.0.0.1:9090`.
