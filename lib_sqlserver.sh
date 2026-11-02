#!/usr/bin/env bash
# lib_sqlserver.sh: SQL Server data fix-ups applied right after a restore, before the upgrade.
#
# SQL Server treats NULLs as equal in a UNIQUE index, so two rows with a NULL or empty key in one
# tenant break a (tenantId, key) unique index that an upgrade creates. MySQL, PostgreSQL and Oracle
# allow many NULLs there, so the same data only fails on SQL Server.
#
# sqlserver_backfill_null_keys <db> <column> <table>...
# Gives every NULL or empty <column> in each named table (found in any schema) a unique value.
# Warns and returns 0 on failure so an import is never blocked by the fix-up.
sqlserver_backfill_null_keys() {
  local db="$1" column="$2"; shift 2
  [[ "${SQLSERVER_BACKFILL_NULL_KEYS:-1}" == "1" && $# -gt 0 ]] || return 0
  local tables="" t
  for t in "$@"; do tables+="${tables:+, }'$t'"; done
  echo "  backfilling NULL/empty $column in [$db] ($*)"
  docker exec -i "${SQLSERVER_CONTAINER:-sqlserver_db}" /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U sa -P "${MSSQL_SA_PASSWORD:-}" -C -b -i /dev/stdin <<SQL || echo "  backfill failed on [$db]; continuing" >&2
SET NOCOUNT ON;
USE [$db];
DECLARE @s sysname, @t sysname, @sql nvarchar(max), @n int;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
  SELECT s.name, t.name FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
  WHERE t.name IN ($tables)
    AND COL_LENGTH(QUOTENAME(s.name) + '.' + QUOTENAME(t.name), '$column') IS NOT NULL;
OPEN c;
FETCH NEXT FROM c INTO @s, @t;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @sql = N'UPDATE ' + QUOTENAME(@s) + N'.' + QUOTENAME(@t)
    + N' SET ' + QUOTENAME('$column') + N' = CONVERT(varchar(36), NEWID())'
    + N' WHERE ' + QUOTENAME('$column') + N' IS NULL OR ' + QUOTENAME('$column') + N' = ''''; SET @n = @@ROWCOUNT;';
  EXEC sp_executesql @sql, N'@n int OUTPUT', @n = @n OUTPUT;
  PRINT '   ' + @s + '.' + @t + ': ' + CONVERT(varchar(12), @n) + ' row(s) backfilled';
  FETCH NEXT FROM c INTO @s, @t;
END
CLOSE c;
DEALLOCATE c;
SQL
}
