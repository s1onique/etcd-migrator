package digest

import (
	"testing"

	"github.com/spbnix/etcd-migrator/internal/dump"
)

func TestDigestRecords_IgnoresMetadata(t *testing.T) {
	// Same key/value, different metadata should produce same digest
	rec1 := dump.NewRecord([]byte("key"), []byte("value"), 1, 1, 1, 1)
	rec2 := dump.NewRecord([]byte("key"), []byte("value"), 999, 999, 999, 999)

	d1, err := DigestRecords([]dump.Record{rec1})
	if err != nil {
		t.Fatalf("DigestRecords failed: %v", err)
	}
	d2, err := DigestRecords([]dump.Record{rec2})
	if err != nil {
		t.Fatalf("DigestRecords failed: %v", err)
	}

	if d1 != d2 {
		t.Errorf("DigestRecords ignores metadata:\n  rec1 metadata: version=1 create_rev=1 mod_rev=1 lease=1\n  rec2 metadata: version=999 create_rev=999 mod_rev=999 lease=999\n  digest1: %s\n  digest2: %s", d1, d2)
	}
}

func TestDigestRecords_IndependentOfInputOrder(t *testing.T) {
	recs := []dump.Record{
		dump.NewRecord([]byte("b"), []byte("val-b"), 1, 1, 2, 0),
		dump.NewRecord([]byte("a"), []byte("val-a"), 1, 1, 1, 0),
		dump.NewRecord([]byte("c"), []byte("val-c"), 1, 1, 3, 0),
	}

	// All permutations should produce the same digest
	digests := make(map[string]int)

	// Try different orders by reordering the slice
	orders := [][]dump.Record{
		{recs[0], recs[1], recs[2]},
		{recs[1], recs[0], recs[2]},
		{recs[2], recs[0], recs[1]},
		{recs[0], recs[2], recs[1]},
	}

	for i, order := range orders {
		d, err := DigestRecords(order)
		if err != nil {
			t.Fatalf("DigestRecords order %d failed: %v", i, err)
		}
		digests[d]++
	}

	if len(digests) != 1 {
		t.Errorf("DigestRecords should be order-independent, got %d different digests", len(digests))
	}
}

func TestDigestRecords_ChangesWhenValueChanges(t *testing.T) {
	rec1 := dump.NewRecord([]byte("key"), []byte("value1"), 1, 1, 1, 0)
	rec2 := dump.NewRecord([]byte("key"), []byte("value2"), 1, 1, 1, 0)

	d1, err := DigestRecords([]dump.Record{rec1})
	if err != nil {
		t.Fatalf("DigestRecords failed: %v", err)
	}
	d2, err := DigestRecords([]dump.Record{rec2})
	if err != nil {
		t.Fatalf("DigestRecords failed: %v", err)
	}

	if d1 == d2 {
		t.Error("DigestRecords should change when value changes")
	}
}

func TestDigestRecords_ChangesWhenKeyChanges(t *testing.T) {
	rec1 := dump.NewRecord([]byte("key1"), []byte("value"), 1, 1, 1, 0)
	rec2 := dump.NewRecord([]byte("key2"), []byte("value"), 1, 1, 1, 0)

	d1, err := DigestRecords([]dump.Record{rec1})
	if err != nil {
		t.Fatalf("DigestRecords failed: %v", err)
	}
	d2, err := DigestRecords([]dump.Record{rec2})
	if err != nil {
		t.Fatalf("DigestRecords failed: %v", err)
	}

	if d1 == d2 {
		t.Error("DigestRecords should change when key changes")
	}
}

func TestDigestRecords_MultipleRecords(t *testing.T) {
	records := []dump.Record{
		dump.NewRecord([]byte("key1"), []byte("value1"), 1, 1, 1, 0),
		dump.NewRecord([]byte("key2"), []byte("value2"), 1, 1, 1, 0),
		dump.NewRecord([]byte("key3"), []byte("value3"), 1, 1, 1, 0),
	}

	digest, err := DigestRecords(records)
	if err != nil {
		t.Fatalf("DigestRecords failed: %v", err)
	}

	// Verify it's a valid SHA-256 hex string (64 chars)
	if len(digest) != 64 {
		t.Errorf("DigestRecords length: got %d, want 64", len(digest))
	}

	// Verify consistency - running again should produce same digest
	digest2, err := DigestRecords(records)
	if err != nil {
		t.Fatalf("DigestRecords re-run failed: %v", err)
	}
	if digest != digest2 {
		t.Error("DigestRecords should be deterministic")
	}
}

func TestDigestRecords_EmptySlice(t *testing.T) {
	digest, err := DigestRecords([]dump.Record{})
	if err != nil {
		t.Fatalf("DigestRecords empty failed: %v", err)
	}
	// SHA-256 of empty input is a known value
	expected := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	if digest != expected {
		t.Errorf("DigestRecords empty: got %s, want %s", digest, expected)
	}
}

func TestDigestRecords_BinaryKeys(t *testing.T) {
	records := []dump.Record{
		dump.NewRecord([]byte{0x00, 0x01, 0x02}, []byte("value1"), 1, 1, 1, 0),
		dump.NewRecord([]byte("/registry/test"), []byte("value2"), 1, 1, 1, 0),
	}

	digest, err := DigestRecords(records)
	if err != nil {
		t.Fatalf("DigestRecords binary keys failed: %v", err)
	}

	// Verify consistency
	digest2, err := DigestRecords(records)
	if err != nil {
		t.Fatalf("DigestRecords re-run failed: %v", err)
	}
	if digest != digest2 {
		t.Error("DigestRecords should handle binary keys deterministically")
	}
}

func TestDigestRecords_UnicodeKeys(t *testing.T) {
	records := []dump.Record{
		dump.NewRecord([]byte("ключ"), []byte("значение"), 1, 1, 1, 0),
	}

	digest, err := DigestRecords(records)
	if err != nil {
		t.Fatalf("DigestRecords unicode failed: %v", err)
	}

	if len(digest) != 64 {
		t.Errorf("DigestRecords unicode length: got %d, want 64", len(digest))
	}
}

func TestDigestRecords_InvalidKeyBase64(t *testing.T) {
	// Invalid base64 in key should return an error (before sorting)
	rec := dump.Record{
		KeyBase64:   "!!!invalid!!!",
		ValueBase64: "dmFsdWU=",
	}

	_, err := DigestRecords([]dump.Record{rec})
	if err == nil {
		t.Error("DigestRecords should return error for invalid key base64")
	}
}

func TestDigestRecords_InvalidValueBase64(t *testing.T) {
	// Invalid base64 in value should return an error (before sorting)
	rec := dump.Record{
		KeyBase64:   "a2V5",
		ValueBase64: "!!!invalid!!!",
	}

	_, err := DigestRecords([]dump.Record{rec})
	if err == nil {
		t.Error("DigestRecords should return error for invalid value base64")
	}
}

func TestDigestRecords_EmptyValue(t *testing.T) {
	// Empty value should be valid
	records := []dump.Record{
		dump.NewRecord([]byte("key"), []byte(""), 1, 1, 1, 0),
	}

	digest, err := DigestRecords(records)
	if err != nil {
		t.Fatalf("DigestRecords with empty value failed: %v", err)
	}

	if len(digest) != 64 {
		t.Errorf("DigestRecords empty value length: got %d, want 64", len(digest))
	}
}
