# Repository agent rules

## Figma safety rule

- Never create a new Figma project, Design file, FigJam board, Slides file, or any other Figma artifact for this repository.
- Never call Figma file-creation tools such as `create_new_file`.
- Mentioning Figma, `@figma`, or a Figma plugin is not permission to create or mutate a Figma file. Treat it as a request for read-only design context or guidance unless the user explicitly overrides this rule.
- When asked to improve an application UI with Figma, implement the result directly in the repository's source files. Do not create a parallel Figma deliverable.
- Do not add, edit, or delete Figma canvas nodes, components, variables, styles, or pages unless the user explicitly overrides this rule and identifies a specific existing Figma file to modify.

## VPS Supabase access rule

- The project's Supabase instance runs on the user's VPS. Codex has no permission to connect to, query, inspect, migrate, or modify that remote Supabase instance.
- Never use the project's Supabase URL, service-role key, REST RPC endpoints, Supabase MCP tools, `psql`, or any other network/database method to access the VPS Supabase unless the user explicitly grants permission in the current turn.
- When a VPS Supabase action is required, provide SQL for the user to run in Supabase SQL Editor. For migrations, follow the SQL-file handoff below. Do not run it on the user's behalf.
- Local code, migrations, and tests may be edited or run in the workspace, but remote migration application and remote verification must always be performed by the user.
- Do not read or use `.env` secrets for remote Supabase access. Treat all remote connection details and service-role keys as user-controlled secrets.

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
3. Provide a separate read-only verification SQL query, with the expected
   result, for the user to run in the same SQL Editor.
4. Treat any PostgreSQL error as a failed migration. Inspect the pasted error
   and provide read-only diagnostic SQL before proposing another attempt; do
   not assume that all preceding statements were rolled back. In particular,
   for `must be owner of function`, inspect `pg_proc.proowner`; do not drop
   functions, change owners, grant role membership, or broaden privileges merely
   to bypass the error.
5. Record remote application as verified only after the user provides successful
   execution output and verification results. Preparing or committing a SQL file
   does not mean the migration has been applied.

Codex must not operate SQL Editor or apply the migration on the user's behalf.
Its role is to prepare the file and verification SQL, inspect the user's pasted
results, and document the verified outcome.
