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
