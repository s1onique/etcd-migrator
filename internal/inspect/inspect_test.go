package inspect

import (
	"strings"
	"testing"

	"github.com/spbnix/etcd-migrator/internal/digest"
	"github.com/spbnix/etcd-migrator/internal/dump"
)

func TestInspectDump_EmptyDump(t *testing.T) {
	input := strings.NewReader("")
	stats, err := InspectDump(input)
	if err != nil {
		t.Fatalf("InspectDump(empty) = %v, want nil", err)
	}
	if stats.Count != 0 {
		t.Errorf("Count = %d, want 0", stats.Count)
	}
	if stats.Digest == "" {
		t.Error("Digest should not be empty for empty dump")
	}
	// Empty dump should have valid empty SHA-256
	if stats.Digest != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" {
		t.Errorf("Digest = %s, want e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", stats.Digest)
	}
}

func TestInspectDump_SingleRecord(t *testing.T) {
	// key="key", value="value" encoded with RawStdEncoding (no padding)
	// Raw bytes: key=3, value=5, total=8
	input := strings.NewReader(`{"key_b64":"a2V5","value_b64":"dmFsdWU","version":1,"create_revision":1,"mod_revision":1,"lease":0}` + "\n")
	stats, err := InspectDump(input)
	if err != nil {
		t.Fatalf("InspectDump(single) = %v, want nil", err)
	}
	if stats.Count != 1 {
		t.Errorf("Count = %d, want 1", stats.Count)
	}
	if stats.KeyBytes != 3 {
		t.Errorf("KeyBytes = %d, want 3", stats.KeyBytes)
	}
	if stats.ValueBytes != 5 {
		t.Errorf("ValueBytes = %d, want 5", stats.ValueBytes)
	}
	if stats.TotalBytes != 8 {
		t.Errorf("TotalBytes = %d, want 8", stats.TotalBytes)
	}
	if stats.LeaseCount != 0 {
		t.Errorf("LeaseCount = %d, want 0", stats.LeaseCount)
	}
	if stats.MinCreateRevision != 1 {
		t.Errorf("MinCreateRevision = %d, want 1", stats.MinCreateRevision)
	}
	if stats.MaxCreateRevision != 1 {
		t.Errorf("MaxCreateRevision = %d, want 1", stats.MaxCreateRevision)
	}
	if stats.MinModRevision != 1 {
		t.Errorf("MinModRevision = %d, want 1", stats.MinModRevision)
	}
	if stats.MaxModRevision != 1 {
		t.Errorf("MaxModRevision = %d, want 1", stats.MaxModRevision)
	}
}

func TestInspectDump_MultipleRecords(t *testing.T) {
	// Records: key1 (4 bytes), key2 (4 bytes), key3 (4 bytes)
	// value1 (6 bytes), value2 (6 bytes), value3 (6 bytes)
	// Total: key=12, value=18, total=30
	// RawStdEncoding: key1->a2V5MQ, key2->a2V5Mg, key3->a2V5Mw
	// value1->dmFsdWUx, value2->dmFsdWUy, value3->dmFsdWUz
	input := strings.NewReader(`{"key_b64":"a2V5MQ","value_b64":"dmFsdWUx","version":1,"create_revision":1,"mod_revision":3,"lease":0}` + "\n" +
		`{"key_b64":"a2V5Mg","value_b64":"dmFsdWUy","version":1,"create_revision":2,"mod_revision":4,"lease":0}` + "\n" +
		`{"key_b64":"a2V5Mw","value_b64":"dmFsdWUz","version":1,"create_revision":5,"mod_revision":5,"lease":0}` + "\n")
	stats, err := InspectDump(input)
	if err != nil {
		t.Fatalf("InspectDump(multiple) = %v, want nil", err)
	}
	if stats.Count != 3 {
		t.Errorf("Count = %d, want 3", stats.Count)
	}
	if stats.KeyBytes != 12 {
		t.Errorf("KeyBytes = %d, want 12 (3 records × 4 bytes)", stats.KeyBytes)
	}
	if stats.ValueBytes != 18 {
		t.Errorf("ValueBytes = %d, want 18 (3 records × 6 bytes)", stats.ValueBytes)
	}
	if stats.TotalBytes != 30 {
		t.Errorf("TotalBytes = %d, want 30 (12 + 18)", stats.TotalBytes)
	}
	// Min create revision should be 1 (lowest non-zero)
	if stats.MinCreateRevision != 1 {
		t.Errorf("MinCreateRevision = %d, want 1", stats.MinCreateRevision)
	}
	// Max create revision should be 5
	if stats.MaxCreateRevision != 5 {
		t.Errorf("MaxCreateRevision = %d, want 5", stats.MaxCreateRevision)
	}
	// Min mod revision should be 3
	if stats.MinModRevision != 3 {
		t.Errorf("MinModRevision = %d, want 3", stats.MinModRevision)
	}
	// Max mod revision should be 5
	if stats.MaxModRevision != 5 {
		t.Errorf("MaxModRevision = %d, want 5", stats.MaxModRevision)
	}
}

func TestInspectDump_InvalidJSON(t *testing.T) {
	input := strings.NewReader(`{"key_b64":"a2V5","value_b64":invalid}`)
	_, err := InspectDump(input)
	if err == nil {
		t.Fatal("InspectDump(invalid JSON) = nil, want error")
	}
}

func TestInspectDump_InvalidKeyBase64(t *testing.T) {
	input := strings.NewReader(`{"key_b64":"!!!","value_b64":"dmFsdWU","version":1,"create_revision":1,"mod_revision":1,"lease":0}` + "\n")
	_, err := InspectDump(input)
	if err == nil {
		t.Fatal("InspectDump(invalid key base64) = nil, want error")
	}
	if err != dump.ErrInvalidKeyBase64 {
		t.Errorf("err = %v, want %v", err, dump.ErrInvalidKeyBase64)
	}
}

func TestInspectDump_InvalidValueBase64(t *testing.T) {
	input := strings.NewReader(`{"key_b64":"a2V5","value_b64":"!!!","version":1,"create_revision":1,"mod_revision":1,"lease":0}` + "\n")
	_, err := InspectDump(input)
	if err == nil {
		t.Fatal("InspectDump(invalid value base64) = nil, want error")
	}
	if err != dump.ErrInvalidValueBase64 {
		t.Errorf("err = %v, want %v", err, dump.ErrInvalidValueBase64)
	}
}

func TestInspectDump_LeaseCount(t *testing.T) {
	// key1=4 bytes, key2=4 bytes, key3=4 bytes = 12 key bytes
	// value1=6 bytes, value2=6 bytes, value3=6 bytes = 18 value bytes
	// RawStdEncoding: key1->a2V5MQ, key2->a2V5Mg, key3->a2V5Mw
	input := strings.NewReader(
		`{"key_b64":"a2V5MQ","value_b64":"dmFsdWUx","version":1,"create_revision":1,"mod_revision":1,"lease":12345}` + "\n" +
			`{"key_b64":"a2V5Mg","value_b64":"dmFsdWUy","version":1,"create_revision":1,"mod_revision":1,"lease":0}` + "\n" +
			`{"key_b64":"a2V5Mw","value_b64":"dmFsdWUz","version":1,"create_revision":1,"mod_revision":1,"lease":67890}` + "\n")
	stats, err := InspectDump(input)
	if err != nil {
		t.Fatalf("InspectDump(lease count) = %v, want nil", err)
	}
	if stats.LeaseCount != 2 {
		t.Errorf("LeaseCount = %d, want 2", stats.LeaseCount)
	}
}

func TestInspectDump_DigestMatchesDigestRecords(t *testing.T) {
	// Create records manually with RawStdEncoding (no padding)
	// key1=4 bytes, value1=6 bytes; key2=4 bytes, value2=6 bytes
	records := []dump.Record{
		{KeyBase64: "a2V5MQ", ValueBase64: "dmFsdWUx", Version: 1, CreateRevision: 1, ModRevision: 1, Lease: 0},
		{KeyBase64: "a2V5Mg", ValueBase64: "dmFsdWUy", Version: 1, CreateRevision: 2, ModRevision: 2, Lease: 0},
	}

	// Build JSONL input
	var builder strings.Builder
	for _, rec := range records {
		recStr := strings.Join([]string{
			`{"key_b64":"` + rec.KeyBase64 + `",`,
			`"value_b64":"` + rec.ValueBase64 + `",`,
			`"version":1,`,
			`"create_revision":1,`,
			`"mod_revision":1,`,
			`"lease":0}`,
		}, "")
		builder.WriteString(recStr + "\n")
	}

	// Get digest from InspectDump
	stats, err := InspectDump(strings.NewReader(builder.String()))
	if err != nil {
		t.Fatalf("InspectDump(digest match) = %v, want nil", err)
	}

	// Get digest directly from DigestRecords
	expectedDigest, err := digest.DigestRecords(records)
	if err != nil {
		t.Fatalf("DigestRecords = %v, want nil", err)
	}

	if stats.Digest != expectedDigest {
		t.Errorf("Digest = %s, want %s", stats.Digest, expectedDigest)
	}
}

func TestInspectDump_MixedZeroNonZeroRevisions(t *testing.T) {
	// Records with mixed zero and non-zero revisions
	// Record 1: create_rev=0, mod_rev=0
	// Record 2: create_rev=5, mod_rev=5
	// Record 3: create_rev=3, mod_rev=7
	// RawStdEncoding: key1->a2V5MQ, key2->a2V5Mg, key3->a2V5Mw
	input := strings.NewReader(`{"key_b64":"a2V5MQ","value_b64":"dmFsdWUx","version":1,"create_revision":0,"mod_revision":0,"lease":0}` + "\n" +
		`{"key_b64":"a2V5Mg","value_b64":"dmFsdWUy","version":1,"create_revision":5,"mod_revision":5,"lease":0}` + "\n" +
		`{"key_b64":"a2V5Mw","value_b64":"dmFsdWUz","version":1,"create_revision":3,"mod_revision":7,"lease":0}` + "\n")
	stats, err := InspectDump(input)
	if err != nil {
		t.Fatalf("InspectDump(mixed revisions) = %v, want nil", err)
	}
	if stats.Count != 3 {
		t.Errorf("Count = %d, want 3", stats.Count)
	}
	// Min create revision should be 3 (ignoring 0)
	if stats.MinCreateRevision != 3 {
		t.Errorf("MinCreateRevision = %d, want 3", stats.MinCreateRevision)
	}
	// Max create revision should be 5
	if stats.MaxCreateRevision != 5 {
		t.Errorf("MaxCreateRevision = %d, want 5", stats.MaxCreateRevision)
	}
	// Min mod revision should be 5 (ignoring 0)
	if stats.MinModRevision != 5 {
		t.Errorf("MinModRevision = %d, want 5", stats.MinModRevision)
	}
	// Max mod revision should be 7
	if stats.MaxModRevision != 7 {
		t.Errorf("MaxModRevision = %d, want 7", stats.MaxModRevision)
	}
}

func TestInspectDump_AllZeroRevisions(t *testing.T) {
	// Records with all zero revisions
	// RawStdEncoding: key1->a2V5MQ, key2->a2V5Mg
	input := strings.NewReader(`{"key_b64":"a2V5MQ","value_b64":"dmFsdWUx","version":1,"create_revision":0,"mod_revision":0,"lease":0}` + "\n" +
		`{"key_b64":"a2V5Mg","value_b64":"dmFsdWUy","version":1,"create_revision":0,"mod_revision":0,"lease":0}` + "\n")
	stats, err := InspectDump(input)
	if err != nil {
		t.Fatalf("InspectDump(all zero revisions) = %v, want nil", err)
	}
	if stats.Count != 2 {
		t.Errorf("Count = %d, want 2", stats.Count)
	}
	// Min/max should remain 0 when all revisions are zero
	if stats.MinCreateRevision != 0 {
		t.Errorf("MinCreateRevision = %d, want 0", stats.MinCreateRevision)
	}
	if stats.MaxCreateRevision != 0 {
		t.Errorf("MaxCreateRevision = %d, want 0", stats.MaxCreateRevision)
	}
	if stats.MinModRevision != 0 {
		t.Errorf("MinModRevision = %d, want 0", stats.MinModRevision)
	}
	if stats.MaxModRevision != 0 {
		t.Errorf("MaxModRevision = %d, want 0", stats.MaxModRevision)
	}
}
