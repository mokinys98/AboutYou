# Repository agent rules

## Figma safety rule

- Never create a new Figma project, Design file, FigJam board, Slides file, or any other Figma artifact for this repository.
- Never call Figma file-creation tools such as `create_new_file`.
- Mentioning Figma, `@figma`, or a Figma plugin is not permission to create or mutate a Figma file. Treat it as a request for read-only design context or guidance unless the user explicitly overrides this rule.
- When asked to improve an application UI with Figma, implement the result directly in the repository's source files. Do not create a parallel Figma deliverable.
- Do not add, edit, or delete Figma canvas nodes, components, variables, styles, or pages unless the user explicitly overrides this rule and identifies a specific existing Figma file to modify.

## VPS Supabase access rule

- The user grants standing permission for Codex to connect to the project's VPS Supabase for read-only inspection and queries without requesting permission each time. Use the user's existing PuTTY SSH tunnel and the `codex_reader` PostgreSQL login from the Windows `%APPDATA%\postgresql\pgpass.conf` file. The current local tunnel endpoint is `127.0.0.1:15432`; check that the tunnel is active before connecting.
- On this Windows setup, `Get-NetTCPConnection` can report no listener on `15432` even while the tunnel and database connection work. Check with `Test-NetConnection 127.0.0.1 -Port 15432`, then verify with a real PostgreSQL connection before declaring the tunnel unavailable. A running PuTTY process alone also does not prove the tunnel works.
- Python `psycopg` is installed for this Windows user; the `psql` CLI may be absent. If needed, connect with `psycopg` using host `127.0.0.1`, port `15432`, database `postgres`, and user `codex_reader`, letting PostgreSQL read the password from `pgpass.conf`. Do not treat missing `psql` as a blocker to read-only inspection.
- This standing permission applies only to read-only PostgreSQL work through that tunnel. Do not use the project's `.env` secrets, service-role key, REST/RPC endpoints, Supabase MCP tools, or other remote access routes under this permission. Never print or copy the password into the repository, commands, logs, or chat.
- Start each database work session with `BEGIN READ ONLY` before inspecting data or metadata. Run only read-only SQL, avoid functions or commands with side effects, and end with `ROLLBACK` and close the connection. Keep result sets bounded where practical.
- Do not rely on the login itself to enforce read-only access: `codex_reader` has `BYPASSRLS`, its default transaction mode is writable, and some objects grant write or `SECURITY DEFINER` function privileges through `PUBLIC`. Never run writes, DDL, migrations, or privilege changes on the VPS through the tunnel, even if PostgreSQL would allow them.
- Local code, migrations, and tests may be edited or run in the workspace. The user applies all VPS database changes manually in Supabase SQL Editor using the handoff below. Codex may perform read-only diagnostics and post-application verification through the authorized tunnel without a new permission request.

### Known VPS migration handoff

VPS database migrations are applied manually by the user through Supabase SQL
Editor. Codex prepares the SQL file; the user opens SQL Editor, loads the file
(or pastes its full contents), and runs it.

- Do not propose or execute migrations through PowerShell, SSH, PuTTY, SCP,
  Docker exec, `psql`, Supabase CLI push, or similar terminal workflows.
- Do not request VPS connection details, SSH keys, passwords, or `.env` secrets
  for this handoff.

For each migration:

1. Create the complete migration file in `supabase/migrations/` and provide a
   clickable link with its exact filename. Use SQL compatible with SQL Editor;
   do not include shell commands or `psql` meta-commands such as `\ir` or `\set`.
2. Explain briefly what the migration changes and tell the user to load that
   file into their VPS Supabase SQL Editor and run it. If the file changes after
   an earlier handoff, explicitly tell the user to load the latest contents.
3. Provide a separate read-only verification SQL query with the expected
   result. The user may run it in SQL Editor; Codex may also run it through the
   authorized read-only tunnel after the user reports applying the migration.
4. Treat any PostgreSQL error as a failed migration. Inspect the pasted error
   and provide read-only diagnostic SQL before proposing another attempt; do
   not assume that all preceding statements were rolled back. In particular,
   for `must be owner of function`, inspect `pg_proc.proowner`; do not drop
   functions, change owners, grant role membership, or broaden privileges merely
   to bypass the error.
5. Record remote application as verified only after the user provides successful
   execution output. Record read-only verification results separately, using
   either the user's pasted SQL Editor results or Codex's authorized read-only
   tunnel queries. Preparing or committing a SQL file does not mean the
   migration has been applied.

Codex must not operate SQL Editor or apply the migration on the user's behalf.
Its role is to prepare the file and verification SQL, inspect the user's pasted
results or run authorized read-only verification, and document the outcome.


# Codex project instructions

For complex coding tasks, use the `astra-orchestrator` skill when its trigger conditions match.

The root agent owns architecture, decomposition, integration, and final verification.
Prefer specialized subagents for bounded exploration, implementation, testing, review, and technical research.

Do not delegate trivial work merely for parallelism.
Do not let multiple implementation agents edit the same files without explicit ownership boundaries.
User instructions always take precedence over this orchestration policy.
