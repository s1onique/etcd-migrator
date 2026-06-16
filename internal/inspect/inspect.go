package inspect

import (
	"io"

	"github.com/spbnix/etcd-migrator/internal/digest"
	"github.com/spbnix/etcd-migrator/internal/dump"
)

// Stats holds statistics about a dump file.
type Stats struct {
	Count             int64
	KeyBytes          int64
	ValueBytes        int64
	TotalBytes        int64
	LeaseCount        int64
	MinCreateRevision int64
	MaxCreateRevision int64
	MinModRevision    int64
	MaxModRevision    int64
	Digest            string
}

// InspectDump reads and validates a JSONL dump, collecting statistics and computing digest.
func InspectDump(r io.Reader) (Stats, error) {
	var records []dump.Record
	var stats Stats

	// First pass: read all records and collect basic stats
	err := dump.ReadRecords(r, func(rec dump.Record) error {
		records = append(records, rec)
		stats.Count++

		// Decode key/value for validation and raw byte counting
		key, err := rec.DecodeKey()
		if err != nil {
			return err
		}
		value, err := rec.DecodeValue()
		if err != nil {
			return err
		}

		// Count raw bytes (decoded lengths), not base64-encoded lengths
		stats.KeyBytes += int64(len(key))
		stats.ValueBytes += int64(len(value))
		stats.TotalBytes += int64(len(key) + len(value))

		// Count leases
		if rec.Lease != 0 {
			stats.LeaseCount++
		}

		// Track min/max create_revision (ignore zeros)
		if rec.CreateRevision != 0 {
			if stats.MinCreateRevision == 0 || rec.CreateRevision < stats.MinCreateRevision {
				stats.MinCreateRevision = rec.CreateRevision
			}
			if rec.CreateRevision > stats.MaxCreateRevision {
				stats.MaxCreateRevision = rec.CreateRevision
			}
		}

		// Track min/max mod_revision (ignore zeros)
		if rec.ModRevision != 0 {
			if stats.MinModRevision == 0 || rec.ModRevision < stats.MinModRevision {
				stats.MinModRevision = rec.ModRevision
			}
			if rec.ModRevision > stats.MaxModRevision {
				stats.MaxModRevision = rec.ModRevision
			}
		}

		return nil
	})
	if err != nil {
		return Stats{}, err
	}

	// Compute digest over all records
	digestStr, err := digest.DigestRecords(records)
	if err != nil {
		return Stats{}, err
	}
	stats.Digest = digestStr

	return stats, nil
}
