---
name: SequelPG codebase conventions for introspection
description: Where introspection queries live, how to add new object categories, and what patterns are used
type: project
---

All PostgreSQL introspection queries are centralized in `DatabaseClient` (actor) in `Services/PostgresClient.swift`. The protocol is `PostgresClientProtocol` — new query methods must be added there first.

Object categories are defined as `ObjectCategory` enum in `ViewModels/NavigatorViewModel.swift`. `SchemaObjects` struct holds one array per category. Adding a new category requires: (1) enum case + icon in `ObjectCategory`, (2) property in `SchemaObjects`, (3) query in `listAllSchemaObjects`, (4) `objects(for:)` switch case, (5) protocol method if needed.

The version gate pattern: `detectServerVersion` returns the PG major version (Int). It is called once per `listAllSchemaObjects` call (not cached separately). PG 10 baseline assumed (fallback = 14). Procedures gated to PG >= 11 in both the query and `availableCategories`.

`getColumns` uses `information_schema.columns` — returns: name, ordinal_position, data_type, is_nullable, column_default, character_maximum_length. Missing: identity columns (is_identity, identity_generation), generated columns (is_generated, generation_expression), udt_name (for enum/domain/composite resolution), numeric_precision/scale, interval_type.

`getPrimaryKeys` uses `pg_index + pg_attribute` — correct pattern, works PG 10-17.

`getApproximateRowCount` uses `pg_class.reltuples::bigint` with fallback to exact COUNT when reltuples = -1. Correct.

**Why:** Understanding these patterns prevents introducing duplicate caching layers or bypassing the protocol when adding new introspection features.

**How to apply:** Always extend `PostgresClientProtocol` + `DatabaseClient` when adding new catalog queries. Never put SQL in ViewModels or Views.
