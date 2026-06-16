package etcdsource

import "bytes"

// PrefixRangeEnd computes the etcd range-end bound for a prefix scan.
// For a non-empty prefix, it increments the last byte that is not 0xff
// and truncates everything after it. If the prefix consists entirely
// of 0xff bytes, the returned range end is nil, indicating that the
// prefix cannot be properly bounded.
func PrefixRangeEnd(prefix []byte) []byte {
	if len(prefix) == 0 {
		return nil
	}
	// Work on a copy so we don't mutate the caller's slice
	result := make([]byte, len(prefix))
	copy(result, prefix)

	// Find the last byte that is not 0xff, counting from the end
	for i := len(result) - 1; i >= 0; i-- {
		if result[i] != 0xff {
			result[i]++
			return result[:i+1]
		}
	}
	// All bytes are 0xff; range cannot be bounded
	return nil
}

// NextKeyAfter returns the key that sorts immediately after key.
// It appends a NUL byte to a copy of key and does not mutate the input.
func NextKeyAfter(key []byte) []byte {
	// Copy to avoid mutating caller's slice
	out := make([]byte, len(key)+1)
	copy(out, key)
	out[len(key)] = 0
	return out
}

// PrefixRangeEndString is like PrefixRangeEnd but accepts and returns strings.
func PrefixRangeEndString(prefix string) string {
	return string(PrefixRangeEnd([]byte(prefix)))
}

// ShouldContinue returns true when startKey has not yet reached rangeEnd.
// This is used to determine whether more pages remain during pagination.
// Uses bytes.Compare to handle binary keys correctly, including those
// containing 0x00 and 0xff bytes.
func ShouldContinue(startKey, rangeEnd []byte) bool {
	return bytes.Compare(startKey, rangeEnd) < 0
}
