---
name: Introspection audit gaps — April 2026
description: Which catalog queries are implemented, which are missing, and the priority order for adding them
type: project
---

Audit performed 2026-04-04 against SequelPG commit at that date.

## Implemented (confirmed in PostgresClient.swift)

- listSchemas — information_schema.schemata (filters pg_catalog, information_schema, pg_% prefixes)
- listTables — information_schema.tables WHERE table_type = 'BASE TABLE'
- listViews — information_schema.views
- listMaterializedViews — pg_matviews
- listFunctions — information_schema.routines WHERE routine_type = 'FUNCTION' (DISTINCT on name only — loses overloads)
- listSequences — information_schema.sequences
- listTypes — pg_type WHERE typtype IN ('e','c','d','r'), excludes table/view/matview/sequence rowtypes
- listAggregates — pg_proc WHERE prokind='a' (PG>=11) or proisagg=true (PG10)
- listCollations — pg_collation
- listDomains — information_schema.domains
- listFTSConfigs — pg_ts_config
- listFTSDictionaries — pg_ts_dict
- listFTSParsers — pg_ts_parser
- listFTSTemplates — pg_ts_template
- listForeignTables — pg_class WHERE relkind='f'
- listOperators — pg_operator (name only; loses left/right operand types — operators are overloaded)
- listProcedures — pg_proc WHERE prokind='p', gated PG>=11
- listTriggerFunctions — pg_proc JOIN pg_type WHERE typname='trigger'
- getColumns — information_schema.columns (7 fields)
- getPrimaryKeys — pg_index + pg_attribute
- getApproximateRowCount — pg_class.reltuples with COUNT fallback
- listDatabases — pg_database WHERE NOT datistemplate
- detectServerVersion — SHOW server_version_num

## Known Query Defects

1. listFunctions uses DISTINCT on routine_name — hides overloaded functions with same name but different signatures
2. listOperators returns only oprname — operators with the same symbol but different types appear as duplicates / are de-duplicated incorrectly
3. listSchemas filter uses LIKE 'pg_%' which would hide user schemas whose names start with "pg_" (unlikely but incorrect)
4. getColumns missing fields: is_identity, identity_generation, is_generated, generation_expression, udt_name, numeric_precision, numeric_scale, interval_type
5. detectServerVersion is called on every listAllSchemaObjects call — result is not cached in DatabaseClient; minor perf issue
6. listAllSchemaObjects fires listTables/listViews/listMatViews/listFunctions/listSequences/listTypes as individual cached calls AND the rest inline — inconsistent caching strategy for the extended categories

## Missing Introspection Capabilities (not implemented anywhere)

### Critical gaps (P0)
- Table indexes — pg_indexes or pg_index join pg_class; needed for performance analysis
- Foreign key constraints — pg_constraint WHERE contype='f'; essential for schema understanding
- Check constraints — pg_constraint WHERE contype='c'
- Unique constraints — pg_constraint WHERE contype='u'
- Table triggers — pg_trigger join pg_class
- Table row count per table (only approximate exists; no per-table summary in navigator)

### High priority (P1)
- Function/procedure DDL source — pg_get_functiondef(oid) or information_schema.routines.routine_definition
- View DDL source — pg_get_viewdef(oid) or information_schema.views.view_definition
- Materialized view DDL — pg_get_viewdef(oid, true)
- Sequence details — min_value, max_value, increment_by, cycle, current value (pg_sequences view, PG10+)
- Type details — enum labels (pg_enum), composite attributes (pg_attribute), domain base type + constraints
- Table statistics — pg_stat_user_tables: n_live_tup, n_dead_tup, last_vacuum, last_analyze, last_autovacuum
- Index details — pg_indexes.indexdef, index type, unique/partial flag, size via pg_relation_size

### Medium priority (P2)
- Extensions installed — pg_extension
- Publications / subscriptions — pg_publication, pg_subscription (PG10+ logical replication)
- Roles and privileges — pg_roles, information_schema.role_table_grants
- Table/column comments — pg_description via obj_description() / col_description()
- Partitioned table structure — pg_inherits, pg_partitioned_table (PG10+ declarative partitioning)
- Foreign data wrappers + servers — pg_foreign_data_wrapper, pg_foreign_server
- Rules — pg_rules
- Event triggers — pg_event_trigger (PG9.3+)

### Lower priority (P3)
- Tablespaces — pg_tablespace
- Server config parameters — pg_settings
- Active connections — pg_stat_activity
- Locks — pg_locks join pg_stat_activity
- Replication slots — pg_replication_slots
- pg_stat_statements (requires extension)

**Why:** These gaps were identified during the April 2026 audit. The P0 items are expected by any DBA using the tool for schema navigation.

**How to apply:** When the user asks to add introspection features, start from P0 and work down. Each requires extending PostgresClientProtocol, DatabaseClient, and likely a new detail panel or tab in the UI.
