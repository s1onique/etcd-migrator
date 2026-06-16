// Package kine provides reading from Kine-backed PostgreSQL datastores.
package kine

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"

	_ "github.com/lib/pq"
	"github.com/spbnix/etcd-migrator/internal/digest"
	"github.com/spbnix/etcd-migrator/internal/dump"
)

// DumpStats holds statistics from a Kine PostgreSQL dump.
type DumpStats struct {
	Count          int
	KeyBytes       int
	ValueBytes     int
	TotalBytes     int
	LeaseCount     int
	MinCreateRev   int64
	MaxCreateRev   int64
	MinModRev      int64
	MaxModRev      int64
	Digest         string
	HeaderRevision int64
}

// KineRow represents a row in the Kine kine table.
// Kine's PostgreSQL driver uses: id, name, created, deleted, create_revision,
// prev_revision, lease, value, old_value
type KineRow struct {
	ID             int64
	Name           []byte
	Created        int64
	Deleted        int64
	CreateRevision int64
	PrevRevision   int64
	Lease          int64
	Value          []byte
	OldValue       []byte
}

// DumpPostgres reads all k/v pairs from a Kine PostgreSQL source and writes
// them as JSONL dump records. It filters out deleted rows and produces
// deterministic output ordered by key.
func DumpPostgres(ctx context.Context, cfg Config, w io.Writer) (*DumpStats, error) {
	if cfg.DSN == "" {
		return nil, errors.New("missing --postgres-dsn")
	}
	if cfg.Prefix == "" {
		return nil, errors.New("prefix cannot be empty")
	}
	if w == nil {
		return nil, errors.New("output writer is required")
	}

	db, err := sql.Open("postgres", cfg.DSN)
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}
	defer db.Close()

	// Set connection timeouts
	if cfg.DialTimeout > 0 {
		_, err = db.ExecContext(ctx, fmt.Sprintf("SET statement_timeout = %d", cfg.DialTimeout.Milliseconds()))
		if err != nil {
			return nil, fmt.Errorf("set dial timeout: %w", err)
		}
	}

	// Verify connection
	if err := db.PingContext(ctx); err != nil {
		return nil, fmt.Errorf("ping postgres: %w", err)
	}

	// Check that kine table exists
	var tableExists bool
	err = db.QueryRowContext(ctx, "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'kine')").Scan(&tableExists)
	if err != nil {
		return nil, fmt.Errorf("check kine table: %w", err)
	}
	if !tableExists {
		return nil, errors.New("kine table does not exist in database")
	}

	batchSize := cfg.BatchSize
	if batchSize <= 0 {
		batchSize = 1000
	}

	// Initial range bounds for prefix scan
	rangeStart := cfg.Prefix
	rangeEnd := nextPrefixKey(cfg.Prefix)
	lastName := "" // Cursor for pagination: last key seen

	var allRecords []dump.Record
	var stats DumpStats

	// seen tracks keys to detect any query regression that produces duplicates.
	// This is a fail-closed invariant: any duplicate key is a dump error,
	// not an etcd transaction error later.
	seen := make(map[string]struct{})

	for {
		// Kine's current-view semantics requires selecting the latest row per name
		// FIRST (via MAX(id) GROUP BY name), then filtering deleted=0. This prevents
		// resurrecting deleted Kubernetes objects that were replaced.
		//
		// The query shape mirrors Kine's own list path which uses:
		//   SELECT MAX(id) ... GROUP BY name
		//   JOIN ... WHERE deleted = 0 OR includeDeleted
		//
		// Pagination uses lastName cursor to avoid NUL-byte issues with PostgreSQL text type.
		query := `
			SELECT kv.id, kv.name, kv.created, kv.deleted, kv.create_revision,
			       kv.prev_revision, kv.lease, kv.value, kv.old_value
			FROM kine AS kv
			JOIN (
			  SELECT MAX(mkv.id) AS id
			  FROM kine AS mkv
			  WHERE mkv.name >= $1
			    AND mkv.name < $2
			    AND ($3 = '' OR mkv.name > $3)
			  GROUP BY mkv.name
			) AS latest USING (id)
			WHERE kv.deleted = 0
			ORDER BY kv.name
			LIMIT $4
		`

		rows, err := db.QueryContext(ctx, query, rangeStart, rangeEnd, lastName, batchSize)
		if err != nil {
			return nil, fmt.Errorf("query kine: %w", err)
		}

		scannedThisPage := 0
		for rows.Next() {
			var row KineRow
			err := rows.Scan(
				&row.ID,
				&row.Name,
				&row.Created,
				&row.Deleted,
				&row.CreateRevision,
				&row.PrevRevision,
				&row.Lease,
				&row.Value,
				&row.OldValue,
			)
			if err != nil {
				rows.Close()
				return nil, fmt.Errorf("scan row: %w", err)
			}

			// Skip the key-value pair marker rows that Kine uses internally
			// Kine stores metadata in special keys ending with '/prev' or '/next'
			keyStr := string(row.Name)
			if len(keyStr) >= 5 && (keyStr[len(keyStr)-5:] == "/prev" || keyStr[len(keyStr)-5:] == "/next") {
				continue
			}
			if len(keyStr) >= 8 && keyStr[len(keyStr)-8:] == "/compact" {
				continue
			}

			// Fail-closed invariant: the SQL dedup should prevent duplicates,
			// but this guards against any future query regression.
			if _, ok := seen[keyStr]; ok {
				return nil, fmt.Errorf("duplicate live Kine key selected: %s", keyStr)
			}
			seen[keyStr] = struct{}{}

			// Use dump.NewRecord to create properly base64-encoded records
			// Kine doesn't preserve mod_revision or version in PostgreSQL, so we use
			// Created as a proxy for mod_revision and leave version=0
			modRevision := row.Created // Use 'created' as proxy for mod_revision
			rec := dump.NewRecord(row.Name, row.Value,
				0, row.CreateRevision, modRevision, row.Lease)

			if row.Lease > 0 {
				stats.LeaseCount++
			}

			stats.KeyBytes += len(row.Name)
			stats.ValueBytes += len(row.Value)
			stats.Count++

			if row.CreateRevision > 0 {
				if stats.MinCreateRev == 0 || row.CreateRevision < stats.MinCreateRev {
					stats.MinCreateRev = row.CreateRevision
				}
				if row.CreateRevision > stats.MaxCreateRev {
					stats.MaxCreateRev = row.CreateRevision
				}
			}
			if modRevision > 0 {
				if stats.MinModRev == 0 || modRevision < stats.MinModRev {
					stats.MinModRev = modRevision
				}
				if modRevision > stats.MaxModRev {
					stats.MaxModRev = modRevision
				}
			}

			allRecords = append(allRecords, rec)
			lastName = keyStr
			scannedThisPage++
		}

		rows.Close()

		if err := rows.Err(); err != nil {
			return nil, fmt.Errorf("row iteration: %w", err)
		}

		// If we got fewer rows than batch size, we're done
		if scannedThisPage == 0 || scannedThisPage < batchSize {
			break
		}

		// Continue to next page with updated cursor (lastName already set)
	}

	// Write records to JSONL
	for _, rec := range allRecords {
		if err := dump.WriteRecord(w, rec); err != nil {
			return nil, fmt.Errorf("write record: %w", err)
		}
	}

	stats.TotalBytes = stats.KeyBytes + stats.ValueBytes

	// Compute deterministic digest (key/value only, not metadata)
	dig, err := digest.DigestRecords(allRecords)
	if err != nil {
		return nil, fmt.Errorf("compute digest: %w", err)
	}
	stats.Digest = dig

	return &stats, nil
}

// nextPrefixKey calculates the lexicographically next key after a given prefix.
// This is used to bound range queries in PostgreSQL.
func nextPrefixKey(prefix string) string {
	// Handle empty prefix
	if prefix == "" {
		return "\xff"
	}

	// Find the last byte we can increment
	bs := []byte(prefix)
	for i := len(bs) - 1; i >= 0; i-- {
		if bs[i] < 0xff {
			bs[i]++
			return string(bs[:i+1])
		}
	}
	// All bytes are 0xff, return as-is (unlikely with /registry/ keys)
	return prefix + "\x00"
}
