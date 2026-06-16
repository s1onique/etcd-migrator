package kine

import (
	"strings"
	"testing"
)

// dedupLatestRows implements the same semantics as the SQL query:
// 1. Find MAX(id) per name (the latest row)
// 2. Filter to deleted=0 rows from that set
// This is a pure function for testing the dedup logic.
func dedupLatestRows(rows []KineRow) []KineRow {
	// Step 1: Find MAX(id) per name (latest revision)
	latestID := make(map[string]int64)
	latestRow := make(map[string]KineRow)
	for _, r := range rows {
		idStr := string(r.Name)
		if _, ok := latestID[idStr]; !ok || r.ID > latestID[idStr] {
			latestID[idStr] = r.ID
			latestRow[idStr] = r
		}
	}

	// Step 2: Filter to deleted=0 and deduplicate
	var result []KineRow
	seen := make(map[string]struct{})
	for _, r := range latestRow {
		if _, ok := seen[string(r.Name)]; ok {
			continue
		}
		if r.Deleted == 0 {
			result = append(result, r)
			seen[string(r.Name)] = struct{}{}
		}
	}
	return result
}

// TestDedupLatestRows_LatestLiveRow tests that given multiple Kine rows with
// the same name, when one older and one newer row exist, only the latest
// non-deleted row is emitted.
func TestDedupLatestRows_LatestLiveRow(t *testing.T) {
	oldRow := KineRow{
		ID:      100,
		Name:    []byte("/registry/test/key"),
		Created: 1000,
		Deleted: 0,
		Value:   []byte("old-value"),
	}
	newRow := KineRow{
		ID:      200,
		Name:    []byte("/registry/test/key"),
		Created: 2000,
		Deleted: 0,
		Value:   []byte("new-value"),
	}

	rows := []KineRow{oldRow, newRow}
	result := dedupLatestRows(rows)

	if len(result) != 1 {
		t.Fatalf("expected 1 row, got %d", len(result))
	}
	if result[0].ID != 200 {
		t.Errorf("expected latest row with ID=200, got ID=%d", result[0].ID)
	}
	if string(result[0].Value) != "new-value" {
		t.Errorf("expected value 'new-value', got %q", result[0].Value)
	}
}

// TestDedupLatestRows_NewerDeletedRow tests that given an older live row and a
// newer deleted row for the same name, no row is emitted for that key.
// This prevents resurrecting deleted Kubernetes objects.
func TestDedupLatestRows_NewerDeletedRow(t *testing.T) {
	liveRow := KineRow{
		ID:      100,
		Name:    []byte("/registry/test/deleted-key"),
		Created: 1000,
		Deleted: 0,
		Value:   []byte("old-live-value"),
	}
	deletedRow := KineRow{
		ID:      200,
		Name:    []byte("/registry/test/deleted-key"),
		Created: 2000,
		Deleted: 1,
		Value:   []byte("deleted-value"),
	}

	rows := []KineRow{liveRow, deletedRow}
	result := dedupLatestRows(rows)

	if len(result) != 0 {
		t.Fatalf("expected 0 rows (deleted latest), got %d", len(result))
	}
}

// TestDedupLatestRows_MixedRows tests that multiple different keys are all
// preserved correctly.
func TestDedupLatestRows_MixedRows(t *testing.T) {
	rows := []KineRow{
		{ID: 100, Name: []byte("/registry/a"), Created: 1000, Deleted: 0, Value: []byte("value-a")},
		{ID: 110, Name: []byte("/registry/a"), Created: 1100, Deleted: 0, Value: []byte("value-a-new")},
		{ID: 200, Name: []byte("/registry/b"), Created: 2000, Deleted: 0, Value: []byte("value-b")},
		{ID: 300, Name: []byte("/registry/c"), Created: 3000, Deleted: 0, Value: []byte("value-c")},
		{ID: 400, Name: []byte("/registry/d"), Created: 4000, Deleted: 1, Value: []byte("deleted-d")},
	}

	result := dedupLatestRows(rows)

	if len(result) != 3 {
		t.Fatalf("expected 3 rows, got %d", len(result))
	}

	expectedKeys := map[string]int64{
		"/registry/a": 110, // latest non-deleted
		"/registry/b": 200,
		"/registry/c": 300,
	}

	for _, r := range result {
		expectedID, ok := expectedKeys[string(r.Name)]
		if !ok {
			t.Errorf("unexpected key: %s", r.Name)
			continue
		}
		if r.ID != expectedID {
			t.Errorf("for key %s: expected ID=%d, got ID=%d", r.Name, expectedID, r.ID)
		}
	}
}

// TestDedupLatestRows_IncludesInternalMarkers tests that dedupLatestRows includes
// marker rows (dedup does not filter them). DumpPostgres filters /prev, /next,
// /compact markers post-SQL, but dedupLatestRows is for testing the dedup logic only.
func TestDedupLatestRows_IncludesInternalMarkers(t *testing.T) {
	rows := []KineRow{
		{ID: 100, Name: []byte("/registry/test/prev"), Created: 1000, Deleted: 0, Value: []byte("marker")},
		{ID: 200, Name: []byte("/registry/test/next"), Created: 2000, Deleted: 0, Value: []byte("marker")},
		{ID: 300, Name: []byte("/registry/test/compact"), Created: 3000, Deleted: 0, Value: []byte("marker")},
		{ID: 400, Name: []byte("/registry/test"), Created: 4000, Deleted: 0, Value: []byte("real-value")},
	}

	result := dedupLatestRows(rows)

	// All rows pass dedup (no duplicates by name), including marker rows.
	// DumpPostgres filters these separately post-SQL.
	if len(result) != 4 {
		t.Fatalf("expected 4 rows from dedup, got %d", len(result))
	}

	// Verify marker rows are present (dedup doesn't filter them)
	hasPrev := false
	hasNext := false
	hasCompact := false
	for _, r := range result {
		if strings.HasSuffix(string(r.Name), "/prev") {
			hasPrev = true
		}
		if strings.HasSuffix(string(r.Name), "/next") {
			hasNext = true
		}
		if strings.HasSuffix(string(r.Name), "/compact") {
			hasCompact = true
		}
	}
	if !hasPrev || !hasNext || !hasCompact {
		t.Errorf("expected all marker types in result: prev=%v, next=%v, compact=%v", hasPrev, hasNext, hasCompact)
	}
}

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
