# Repository agent rules

## Figma safety rule

- Never create a new Figma project, Design file, FigJam board, Slides file, or any other Figma artifact for this repository.
- Never call Figma file-creation tools such as `create_new_file`.
- Mentioning Figma, `@figma`, or a Figma plugin is not permission to create or mutate a Figma file. Treat it as a request for read-only design context or guidance unless the user explicitly overrides this rule.
- When asked to improve an application UI with Figma, implement the result directly in the repository's source files. Do not create a parallel Figma deliverable.
- Do not add, edit, or delete Figma canvas nodes, components, variables, styles, or pages unless the user explicitly overrides this rule and identifies a specific existing Figma file to modify.
