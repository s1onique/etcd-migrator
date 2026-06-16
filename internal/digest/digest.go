package digest

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"sort"

	"github.com/spbnix/etcd-migrator/internal/dump"
)

// keyValue holds pre-decoded key/value pairs for sorting and hashing.
type keyValue struct {
	key   []byte
	value []byte
}

// DigestRecords computes a deterministic SHA-256 digest over the key/value pairs
// in records. The digest is stable regardless of input order:
//   - Records are pre-decoded and sorted by raw key
//   - Only raw key and value bytes are hashed (not metadata)
//
// Digest format: sha256( sorted records by raw key, each as key + NUL + value + NUL )
func DigestRecords(records []dump.Record) (string, error) {
	// Pre-decode all records before sorting
	pairs := make([]keyValue, len(records))
	for i, rec := range records {
		key, err := rec.DecodeKey()
		if err != nil {
			return "", err
		}
		value, err := rec.DecodeValue()
		if err != nil {
			return "", err
		}
		pairs[i] = keyValue{key: key, value: value}
	}

	// Sort by raw key using bytes.Compare
	sort.Slice(pairs, func(i, j int) bool {
		return bytes.Compare(pairs[i].key, pairs[j].key) < 0
	})

	// Compute digest over key + NUL + value + NUL for each pair
	h := sha256.New()
	for _, pair := range pairs {
		h.Write(pair.key)
		h.Write([]byte{0})
		h.Write(pair.value)
		h.Write([]byte{0})
	}

	return hex.EncodeToString(h.Sum(nil)), nil
}
