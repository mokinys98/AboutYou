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
- When a VPS Supabase action is required, stop and provide the exact command or SQL for the user to run. Do not run it on the user's behalf.
- Local code, migrations, and tests may be edited or run in the workspace, but remote migration application and remote verification must always be performed by the user.
- Do not read or use `.env` secrets for remote Supabase access. Treat all remote connection details and service-role keys as user-controlled secrets.

### Known VPS migration handoff

Use these already-confirmed connection details when preparing commands for the
user. Do not ask for them again unless the user says they changed or a command
shows that they are no longer valid.

- VPS IP: `169.58.26.120`
- SSH user: `deploy`
- SSH host key: `SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q`
- PuTTY private key: `C:\Users\Auris\Documents\contabo.ppk`
- PuTTY tools: `C:\Program Files\PuTTY\pageant.exe`, `pscp.exe`, and `plink.exe`
- Supabase database container: `supabase-db`
- Database and role normally used for project migrations: `postgres`

The `.ppk` is a private, passphrase-protected key. Never read it, print it,
copy it into the repository, or describe it as a public key. OpenSSH `ssh` does
not directly use this PuTTY key. Authentication must use Pageant and PuTTY's
`-agent` option.

The `deploy` user's `sudo` requires an interactive password. Therefore never
pipe migration SQL through Plink's stdin, never use `sudo -n`, and never try to
include the sudo password in a command. Upload the SQL file first, open an
interactive SSH session, and let the user enter the sudo password there.

For a migration named `<migration-file.sql>`, provide this workflow with the
placeholder replaced by the exact real filename.

1. If Pageant does not already hold the key, start it from PowerShell and let
   the user enter the private-key passphrase in the Pageant window:

   ```powershell
   Start-Process -FilePath "C:\Program Files\PuTTY\pageant.exe" `
     -ArgumentList '"C:\Users\Auris\Documents\contabo.ppk"'
   ```

2. Upload the current local migration file to `/tmp` on the VPS. If the file
   was changed after an earlier upload, always upload it again before execution:

   ```powershell
   & "C:\Program Files\PuTTY\pscp.exe" `
     -agent `
     -hostkey "SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q" `
     ".\supabase\migrations\<migration-file.sql>" `
     deploy@169.58.26.120:/tmp/<migration-file.sql>
   ```

3. Open an interactive VPS session:

   ```powershell
   & "C:\Program Files\PuTTY\plink.exe" `
     -agent `
     -hostkey "SHA256:U5Km9Q2qF4HFi5E5Wiu6R8c1ZfWes6xHXnSXp/xN36Q" `
     deploy@169.58.26.120
   ```

4. In the VPS shell, run the uploaded migration and have the user enter the
   `deploy` sudo password when prompted:

   ```bash
   sudo docker exec -i supabase-db psql -X -v ON_ERROR_STOP=1 \
     -U postgres -d postgres \
     < /tmp/<migration-file.sql>
   ```

5. Treat any PostgreSQL error as a stopped/failed migration because
   `ON_ERROR_STOP=1` is enabled. Diagnose it with read-only SQL before proposing
   another attempt. In particular, if PostgreSQL reports `must be owner of
   function`, inspect `pg_proc.proowner`; do not drop functions, change owners,
   grant role membership, or broaden privileges merely to bypass the error.

6. Only after successful migration output and the required verification query
   may the user remove that exact temporary file:

   ```bash
   rm -f /tmp/<migration-file.sql>
   exit
   ```

Codex still must not execute any of these remote commands itself without an
explicit current-turn override of the VPS access rule. Its default role is to
prepare the exact filename-specific commands, ask the user to run them, inspect
the pasted output, and record verified results in the relevant documentation.
