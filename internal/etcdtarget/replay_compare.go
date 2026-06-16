package etcdtarget

import (
	"fmt"

	"github.com/spbnix/etcd-migrator/internal/dump"
	"github.com/spbnix/etcd-migrator/internal/keyrange"
)

// ReplayCompareResult describes the outcome of comparing dump records against target KV data.
type ReplayCompareResult struct {
	// IsIdentical means target exactly matches dump (allowed for replay).
	IsIdentical bool
	// IsEmpty means target has no keys under prefix (allowed for first load).
	IsEmpty bool
	// IsPartial means target has fewer keys than dump.
	IsPartial bool
	// IsExtra means target has more keys than dump (or extra keys not in dump).
	IsExtra bool
	// IsDivergent means target has same keys but different values.
	IsDivergent bool
	// ExtraKeys lists any keys in target not present in dump.
	ExtraKeys []string
	// DivergentKeys lists any keys with divergent values.
	DivergentKeys []string
}

// CompareDumpToTarget compares dump records against target KV data.
// Returns whether the comparison succeeded and the result of the comparison.
// This is a pure function suitable for testing without etcd.
// The comparison is scoped to the migration prefix only.
func CompareDumpToTarget(cfg Config, records []dump.Record, targetKVs map[string][]byte) (ReplayCompareResult, error) {
	if err := validatePrefix(cfg.Prefix); err != nil {
		return ReplayCompareResult{}, err
	}

	// Build dump KV map from records
	dumpKVs := make(map[string][]byte, len(records))
	for _, rec := range records {
		key, err := rec.DecodeKey()
		if err != nil {
			return ReplayCompareResult{}, fmt.Errorf("decode key: %w", err)
		}
		value, err := rec.DecodeValue()
		if err != nil {
			return ReplayCompareResult{}, fmt.Errorf("decode value: %w", err)
		}
		dumpKVs[string(key)] = value
	}

	// Filter target KVs to only include keys under the migration prefix.
	// Keys outside the prefix are ignored per the operator contract.
	filteredTargetKVs := make(map[string][]byte)
	for key, value := range targetKVs {
		if KeyHasPrefix([]byte(key), cfg.Prefix) {
			filteredTargetKVs[key] = value
		}
	}

	// Empty target under the migration prefix is allowed (first load scenario).
	if len(filteredTargetKVs) == 0 {
		return ReplayCompareResult{IsEmpty: true, IsIdentical: true}, nil
	}

	// Check key count mismatch against filtered target (only prefix keys)
	if len(filteredTargetKVs) != len(dumpKVs) {
		// Collect extra keys before returning (from filtered set)
		var extraKeys []string
		for key := range filteredTargetKVs {
			if _, ok := dumpKVs[key]; !ok {
				extraKeys = append(extraKeys, key)
			}
		}
		if len(filteredTargetKVs) < len(dumpKVs) {
			return ReplayCompareResult{IsPartial: true, ExtraKeys: extraKeys}, nil
		}
		return ReplayCompareResult{IsExtra: true, ExtraKeys: extraKeys}, nil
	}

	// Check for extra keys in target (keys in target not in dump)
	var extraKeys []string
	for key := range filteredTargetKVs {
		if _, ok := dumpKVs[key]; !ok {
			extraKeys = append(extraKeys, key)
		}
	}
	if len(extraKeys) > 0 {
		return ReplayCompareResult{
			IsExtra:   true,
			ExtraKeys: extraKeys,
		}, nil
	}

	// Check for divergent values
	var divergentKeys []string
	for key, targetVal := range filteredTargetKVs {
		dumpVal, ok := dumpKVs[key]
		if !ok {
			continue
		}
		if string(targetVal) != string(dumpVal) {
			divergentKeys = append(divergentKeys, key)
		}
	}
	if len(divergentKeys) > 0 {
		return ReplayCompareResult{
			IsDivergent:   true,
			DivergentKeys: divergentKeys,
		}, nil
	}

	// Target exactly matches dump
	return ReplayCompareResult{IsIdentical: true}, nil
}

// validatePrefix checks that the prefix can be bounded for range queries.
func validatePrefix(prefix string) error {
	rangeEnd := keyrange.PrefixRangeEndString(prefix)
	if rangeEnd == "" {
		return fmt.Errorf("prefix %q cannot be bounded for range check", prefix)
	}
	return nil
}
