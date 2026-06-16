package etcdsource

import (
	"context"
	"fmt"
	"io"

	"github.com/spbnix/etcd-migrator/internal/digest"
	"github.com/spbnix/etcd-migrator/internal/dump"
	"go.etcd.io/etcd/client/v3"
)

// Stats holds statistics about a completed dump operation.
type Stats struct {
	Count          int64
	Bytes          int64
	Prefix         string
	HeaderRevision int64
	Digest         string
}

// DumpPrefix reads all keys under cfg.Prefix from an etcd v3 endpoint
// and writes JSONL dump records to w. It pages through the keyspace,
// records metadata, and computes a deterministic digest over raw key/value
// pairs.
//
// Dump does not preserve revision history, watches, compaction state, or
// lease identity. It records key, value, version, create_revision,
// mod_revision, and lease but these metadata fields are not restored.
func DumpPrefix(ctx context.Context, cfg Config, w io.Writer) (Stats, error) {
	cfg = cfg.WithDefaults()
	if err := cfg.Validate(); err != nil {
		return Stats{}, fmt.Errorf("etcd source: %w", err)
	}

	cli, err := clientv3.New(clientv3.Config{
		Endpoints:   cfg.Endpoints,
		DialTimeout: cfg.DialTimeout,
	})
	if err != nil {
		return Stats{}, fmt.Errorf("etcd source: dial: %w", err)
	}
	defer cli.Close()

	// Determine bounding range
	startKey := []byte(cfg.Prefix)
	rangeEnd := PrefixRangeEnd(startKey)
	if rangeEnd == nil {
		return Stats{}, fmt.Errorf("etcd source: prefix %q cannot be bounded; all bytes are 0xff", cfg.Prefix)
	}

	// Collect records for digest; hold in memory for now
	var records []dump.Record
	var totalBytes int64
	var headerRev int64
	var stats = Stats{Prefix: cfg.Prefix}

	for {
		// Build options per page
		var getOpts []clientv3.OpOption
		getOpts = append(getOpts,
			clientv3.WithRange(string(rangeEnd)),
			clientv3.WithSort(clientv3.SortByKey, clientv3.SortAscend),
			clientv3.WithLimit(cfg.BatchSize),
		)

		// Pin to header revision for all pages after the first
		if headerRev > 0 {
			getOpts = append(getOpts, clientv3.WithRev(headerRev))
		}

		// Use per-page request context with timeout; cancel immediately after request
		pageCtx, cancel := context.WithTimeout(ctx, cfg.RequestTimeout)
		resp, err := cli.Get(pageCtx, string(startKey), getOpts...)
		cancel()
		if err != nil {
			return Stats{}, fmt.Errorf("etcd source: get: %w", err)
		}

		if len(resp.Kvs) == 0 {
			break
		}

		// Capture header revision from first successful response
		if headerRev == 0 && resp.Header != nil {
			headerRev = resp.Header.Revision
		}

		for _, kv := range resp.Kvs {
			rec := dump.NewRecord(kv.Key, kv.Value,
				kv.Version, kv.CreateRevision, kv.ModRevision, kv.Lease)
			if err := dump.WriteRecord(w, rec); err != nil {
				return Stats{}, fmt.Errorf("etcd source: write: %w", err)
			}
			records = append(records, rec)
			totalBytes += int64(len(kv.Key) + len(kv.Value))
			stats.Count++
		}

		// Check for next page using NextKeyAfter
		lastKey := resp.Kvs[len(resp.Kvs)-1].Key
		startKey = NextKeyAfter(lastKey)
		if !ShouldContinue(startKey, rangeEnd) {
			break
		}
	}

	// Compute digest
	d, err := digest.DigestRecords(records)
	if err != nil {
		return Stats{}, fmt.Errorf("etcd source: digest: %w", err)
	}

	return Stats{
		Count:          stats.Count,
		Bytes:          totalBytes,
		Prefix:         cfg.Prefix,
		HeaderRevision: headerRev,
		Digest:         d,
	}, nil
}
