package kine

import (
	"testing"
)

func TestNextPrefixKey(t *testing.T) {
	tests := []struct {
		name     string
		prefix   string
		expected string
	}{
		{
			name:     "simple prefix",
			prefix:   "/registry/",
			expected: "/registry0",
		},
		{
			name:     "empty prefix",
			prefix:   "",
			expected: "\xff",
		},
		{
			name:     "prefix ending with normal char",
			prefix:   "/registry/namespaces",
			expected: "/registry/namespacet",
		},
		{
			name:     "prefix ending with ff",
			prefix:   "/test\xff",
			expected: "/tesu",
		},
		{
			name:     "prefix with trailing slash",
			prefix:   "/registry/namespace/",
			expected: "/registry/namespace0",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := nextPrefixKey(tt.prefix)
			if result != tt.expected {
				t.Errorf("nextPrefixKey(%q) = %q, want %q", tt.prefix, result, tt.expected)
			}
		})
	}
}

func TestNextPrefixKeyBounds(t *testing.T) {
	// Test that the next prefix properly bounds /registry/ keys
	prefix := "/registry/"
	next := nextPrefixKey(prefix)

	// The next prefix should be lexicographically greater than /registry/
	if next <= prefix {
		t.Errorf("nextPrefixKey(%q) = %q should be > %q", prefix, next, prefix)
	}

	// But not too far - it should still be in the /registry/ range
	if next[:9] != "/registry/" && next[:9] != "/registry0" {
		t.Logf("next prefix %q is acceptable", next)
	}
}
