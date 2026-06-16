package etcdtarget

import (
	"context"
	"fmt"
	"io"

	"go.etcd.io/etcd/client/v3"

	"github.com/spbnix/etcd-migrator/internal/digest"
	"github.com/spbnix/etcd-migrator/internal/dump"
	"github.com/spbnix/etcd-migrator/internal/keyrange"
)

// LoadDump reads JSONL dump records from r and writes raw keys/values to target etcd.
//
// Two-phase behavior prevents partial writes from malformed input:
//   - Phase 1: Validate all input locally (decode, prefix-check)
//   - Phase 2: Write to target etcd only if phase 1 succeeds completely
//
// LoadDump is guarded by an empty-target-prefix check when RequireEmpty is true.
// LoadDump does not restore version, create_revision, mod_revision, or lease.
func LoadDump(ctx context.Context, cfg Config, r io.Reader) (Stats, error) {
	cfg = cfg.WithDefaults()
	if err := cfg.Validate(); err != nil {
		return Stats{}, err
	}

	// Phase 1: Read and validate ALL dump records before any writes.
	// This ensures malformed input fails before touching target etcd.
	allRecords, count, totalBytes, err := readAndValidateDump(r, cfg.Prefix)
	if err != nil {
		return Stats{}, fmt.Errorf("validate dump: %w", err)
	}

	// Compute digest from all validated records.
	dig, err := digest.DigestRecords(allRecords)
	if err != nil {
		return Stats{}, fmt.Errorf("compute digest: %w", err)
	}

	// Phase 2: Connect to target etcd and write only after full validation.
	cli, err := clientv3.New(clientv3.Config{
		Endpoints:   cfg.Endpoints,
		DialTimeout: cfg.DialTimeout,
	})
	if err != nil {
		return Stats{}, fmt.Errorf("create etcd client: %w", err)
	}
	defer cli.Close()

	// Check target prefix emptiness if required.
	if cfg.RequireEmpty {
		if err := checkEmpty(ctx, cli, cfg); err != nil {
			return Stats{}, err
		}
	}

	// Write all records in batches.
	if err := writeAllRecords(ctx, cli, cfg, allRecords); err != nil {
		return Stats{}, fmt.Errorf("write records: %w", err)
	}

	return Stats{
		Count:  count,
		Bytes:  totalBytes,
		Prefix: cfg.Prefix,
		Digest: dig,
	}, nil
}

// readAndValidateDump reads all records from r, validates them, and returns
// the complete set. Returns an error on first malformed record.
// This ensures no partial writes from invalid input.
func readAndValidateDump(r io.Reader, prefix string) ([]dump.Record, int64, int64, error) {
	var allRecords []dump.Record
	var count int64
	var totalBytes int64

	err := dump.ReadRecords(r, func(rec dump.Record) error {
		key, err := rec.DecodeKey()
		if err != nil {
			return fmt.Errorf("decode key: %w", err)
		}

		value, err := rec.DecodeValue()
		if err != nil {
			return fmt.Errorf("decode value: %w", err)
		}

		// Reject keys outside prefix.
		if !KeyHasPrefix(key, prefix) {
			return fmt.Errorf("key %q outside prefix %q", string(key), prefix)
		}

		allRecords = append(allRecords, rec)
		count++
		totalBytes += int64(len(key) + len(value))

		return nil
	})
	if err != nil {
		return nil, 0, 0, err
	}

	return allRecords, count, totalBytes, nil
}

// checkEmpty verifies that no keys exist under cfg.Prefix in target etcd.
func checkEmpty(ctx context.Context, cli *clientv3.Client, cfg Config) error {
	rangeEnd := keyrange.PrefixRangeEndString(cfg.Prefix)
	if rangeEnd == "" {
		// Empty prefix cannot be bounded; this is a config error.
		return fmt.Errorf("prefix %q cannot be bounded for range check", cfg.Prefix)
	}

	ctx, cancel := context.WithTimeout(ctx, cfg.RequestTimeout)
	defer cancel()

	resp, err := cli.Get(ctx, cfg.Prefix, clientv3.WithRange(rangeEnd), clientv3.WithLimit(1))
	if err != nil {
		return fmt.Errorf("check empty: %w", err)
	}
	if resp.Count > 0 {
		return ErrTargetNotEmpty
	}
	return nil
}

// writeAllRecords writes all records to etcd using batched transactions.
func writeAllRecords(ctx context.Context, cli *clientv3.Client, cfg Config, records []dump.Record) error {
	for i := 0; i < len(records); i += cfg.BatchSize {
		end := i + cfg.BatchSize
		if end > len(records) {
			end = len(records)
		}
		batch := records[i:end]
		if err := flushBatch(ctx, cli, cfg, batch); err != nil {
			return fmt.Errorf("flush batch %d-%d: %w", i, end, err)
		}
	}
	return nil
}

// flushBatch writes a batch of records to etcd using a transaction.
func flushBatch(ctx context.Context, cli *clientv3.Client, cfg Config, records []dump.Record) error {
	// Build operations for each record.
	ops := make([]clientv3.Op, 0, len(records))
	for _, rec := range records {
		key, err := rec.DecodeKey()
		if err != nil {
			return err
		}
		value, err := rec.DecodeValue()
		if err != nil {
			return err
		}
		ops = append(ops, clientv3.OpPut(string(key), string(value)))
	}

	ctx, cancel := context.WithTimeout(ctx, cfg.RequestTimeout)
	defer cancel()

	// Use transaction for atomic batch write.
	txn := clientv3.NewKV(cli).Txn(ctx)
	txn.Then(ops...)
	_, err := txn.Commit()
	if err != nil {
		return fmt.Errorf("txn commit: %w", err)
	}

	return nil
}
