package etcdsource

import (
	"bytes"

	"github.com/spbnix/etcd-migrator/internal/keyrange"
)

// PrefixRangeEnd delegates to keyrange.PrefixRangeEnd.
// Kept for backward compatibility with callers using []byte.
func PrefixRangeEnd(prefix []byte) []byte {
	return keyrange.PrefixRangeEnd(prefix)
}

// NextKeyAfter delegates to keyrange.NextKeyAfter.
func NextKeyAfter(key []byte) []byte {
	return keyrange.NextKeyAfter(key)
}

// PrefixRangeEndString delegates to keyrange.PrefixRangeEndString.
func PrefixRangeEndString(prefix string) string {
	return keyrange.PrefixRangeEndString(prefix)
}

// ShouldContinue delegates to keyrange.ShouldContinue.
func ShouldContinue(startKey, rangeEnd []byte) bool {
	return keyrange.ShouldContinue(startKey, rangeEnd)
}

// PrefixMatches reports whether key starts with prefix.
// Kept for backward compatibility.
func PrefixMatches(key, prefix []byte) bool {
	return bytes.HasPrefix(key, prefix)
}

// ShouldContinueString is like ShouldContinue but accepts strings.
func ShouldContinueString(startKey, rangeEnd string) bool {
	return keyrange.ShouldContinue([]byte(startKey), []byte(rangeEnd))
}
