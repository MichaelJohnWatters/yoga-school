# server

## Audit logging

Every sensitive admin mutation must leave a row in `audit_log`. The matrix at
`internal/api/audit_matrix_test.go` enumerates each (route, action) pair and
asserts a row appears on success — adding a new sensitive admin endpoint
without an entry is the expected failure mode it catches.

When adding a mutation:

1. Write the row in the store layer — prefer `writeAuditTx` inside the same
   transaction so the audit commits atomically with the change. Use
   `WriteAudit` (non-tx) only when the mutation is a single statement.
2. Thread `actorID` through the store function signature; the handler reads
   it from `userFrom(r).ID`.
3. Append a case to `auditMatrix` with a builder that produces a 2xx and the
   `expected_action` string.

Action names are unique across the matrix (`TestAuditMatrix_NonEmpty`
enforces this); reuse an existing name only if both code paths semantically
record the same event (e.g. `class_update` from both scoped and single
branches).

## Role matrix

`internal/api/matrix_test.go` walks every registered route via `chi.Walk` and
asserts the role gates: unauthenticated → 401 (except `authBypassRoutes`),
instructor → 403 on anything under `/api/v1/admin/*` not in
`staffAllowedRoutes`. Adding a new admin route is a deliberate policy choice
— if instructors should see it, add it to `staffAllowedRoutes`; otherwise
the test passes automatically because manager-only is the default.

