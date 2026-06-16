package etcdtarget

import (
	"bytes"
)

// KeyHasPrefix reports whether key starts with prefix.
// Both prefix and key are treated as raw bytes for comparison.
// An empty prefix matches no keys.
func KeyHasPrefix(key []byte, prefix string) bool {
	if prefix == "" {
		return false
	}
	return bytes.HasPrefix(key, []byte(prefix))
}
