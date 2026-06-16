package dump

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestWriteRecord_Basic(t *testing.T) {
	var buf bytes.Buffer
	rec := Record{
		KeyBase64:   "a2V5",
		ValueBase64: "dmFsdWU=",
		Version:     1,
	}
	if err := WriteRecord(&buf, rec); err != nil {
		t.Fatalf("WriteRecord failed: %v", err)
	}
	want := `{"key_b64":"a2V5","value_b64":"dmFsdWU=","version":1,"create_revision":0,"mod_revision":0,"lease":0}`
	got := strings.TrimSuffix(buf.String(), "\n")
	if got != want {
		t.Errorf("WriteRecord output:\n  got:  %s\n  want: %s", got, want)
	}
}

func TestWriteRecord_MissingKey(t *testing.T) {
	var buf bytes.Buffer
	rec := Record{
		KeyBase64:   "",
		ValueBase64: "dmFsdWU=",
	}
	if err := WriteRecord(&buf, rec); err != ErrMissingKeyField {
		t.Errorf("WriteRecord missing key: got %v, want %v", err, ErrMissingKeyField)
	}
}

func TestWriteRecord_EmptyValue(t *testing.T) {
	var buf bytes.Buffer
	rec := Record{
		KeyBase64: "a2V5",
	}
	if err := WriteRecord(&buf, rec); err != nil {
		t.Fatalf("WriteRecord with empty value failed: %v", err)
	}
}

func TestReadRecords_Basic(t *testing.T) {
	input := `{"key_b64":"a2V5","value_b64":"dmFsdWU=","version":1}` + "\n"
	var got []Record
	err := ReadRecords(strings.NewReader(input), func(r Record) error {
		got = append(got, r)
		return nil
	})
	if err != nil {
		t.Fatalf("ReadRecords failed: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("ReadRecords count: got %d, want 1", len(got))
	}
	if got[0].KeyBase64 != "a2V5" {
		t.Errorf("ReadRecords key: got %s, want a2V5", got[0].KeyBase64)
	}
}

func TestReadRecords_MultipleRecords(t *testing.T) {
	input := `{"key_b64":"a2V5MQ==","value_b64":"dmFsdWUx","version":1}` + "\n" +
		`{"key_b64":"a2V5Mg==","value_b64":"dmFsdWUy","version":1}` + "\n" +
		`{"key_b64":"a2V5Mw==","value_b64":"dmFsdWUz","version":1}` + "\n"
	var got []Record
	err := ReadRecords(strings.NewReader(input), func(r Record) error {
		got = append(got, r)
		return nil
	})
	if err != nil {
		t.Fatalf("ReadRecords failed: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("ReadRecords count: got %d, want 3", len(got))
	}
}

func TestReadRecords_MalformedJSON(t *testing.T) {
	input := `{"key_b64":"a2V5","value_b64":"dmFsdWU=" not valid json` + "\n"
	err := ReadRecords(strings.NewReader(input), func(r Record) error {
		return nil
	})
	if err == nil {
		t.Fatal("ReadRecords expected error for malformed JSON")
	}
	var jsonErr *JSONLError
	if !errors.As(err, &jsonErr) {
		t.Errorf("ReadRecords error type: got %T, want *JSONLError", err)
	}
}

func TestReadRecords_MissingKeyField(t *testing.T) {
	input := `{"value_b64":"dmFsdWU=","version":1}` + "\n"
	err := ReadRecords(strings.NewReader(input), func(r Record) error {
		return nil
	})
	if err == nil {
		t.Fatal("ReadRecords expected error for missing key_b64")
	}
}

func TestReadRecords_MissingValueField(t *testing.T) {
	// Missing value_b64 field (not present in JSON)
	input := `{"key_b64":"a2V5","version":1}` + "\n"
	err := ReadRecords(strings.NewReader(input), func(r Record) error {
		return nil
	})
	if err == nil {
		t.Fatal("ReadRecords expected error for missing value_b64")
	}
}

func TestReadRecords_EmptyValueAllowed(t *testing.T) {
	// Explicit empty value_b64 is valid
	input := `{"key_b64":"a2V5","value_b64":"","version":1}` + "\n"
	var got []Record
	err := ReadRecords(strings.NewReader(input), func(r Record) error {
		got = append(got, r)
		return nil
	})
	if err != nil {
		t.Fatalf("ReadRecords with empty value_b64 failed: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("ReadRecords count: got %d, want 1", len(got))
	}
	if got[0].ValueBase64 != "" {
		t.Errorf("ReadRecords empty value: got %q, want \"\"", got[0].ValueBase64)
	}
}

func TestReadRecords_EmptyKeyNotAllowed(t *testing.T) {
	// Empty string key_b64 is not allowed
	input := `{"key_b64":"","value_b64":"dmFsdWU="}` + "\n"
	err := ReadRecords(strings.NewReader(input), func(r Record) error {
		return nil
	})
	if err == nil {
		t.Fatal("ReadRecords expected error for empty key_b64")
	}
}

func TestReadRecords_InvalidBase64(t *testing.T) {
	// This should NOT fail at read time - base64 validation happens in DecodeKey/DecodeValue
	input := `{"key_b64":"!!!not-valid-base64!!!","value_b64":"dmFsdWU="}` + "\n"
	err := ReadRecords(strings.NewReader(input), func(r Record) error {
		return nil
	})
	if err != nil {
		t.Fatalf("ReadRecords should not validate base64 at read time: %v", err)
	}
}

func TestReadRecords_VisitError(t *testing.T) {
	input := `{"key_b64":"a2V5MQ==","value_b64":"dmFsdWUx"}` + "\n" +
		`{"key_b64":"a2V5Mg==","value_b64":"dmFsdWUy"}` + "\n"
	sentinel := errors.New("visit stopped")
	var count int
	err := ReadRecords(strings.NewReader(input), func(r Record) error {
		count++
		if count == 2 {
			return sentinel
		}
		return nil
	})
	if err != sentinel {
		t.Errorf("ReadRecords visit error: got %v, want %v", err, sentinel)
	}
	if count != 2 {
		t.Errorf("ReadRecords visit count: got %d, want 2", count)
	}
}

func TestReadRecords_EmptyLines(t *testing.T) {
	input := `{"key_b64":"a2V5MQ==","value_b64":"dmFsdWUx"}` + "\n" +
		"\n" +
		`{"key_b64":"a2V5Mg==","value_b64":"dmFsdWUy"}` + "\n"
	var got []Record
	err := ReadRecords(strings.NewReader(input), func(r Record) error {
		got = append(got, r)
		return nil
	})
	if err != nil {
		t.Fatalf("ReadRecords failed on empty lines: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ReadRecords count with empty lines: got %d, want 2", len(got))
	}
}

func TestReadRecords_LargeLine(t *testing.T) {
	// Test that lines larger than bufio.Scanner's default 64 KiB limit work
	// Create a very long key_b64 value (> 100 KiB when decoded would be ~75 KiB of base64)
	largeValue := strings.Repeat("x", 100*1024)
	input := `{"key_b64":"a2V5","value_b64":"` + largeValue + `"}` + "\n"

	err := ReadRecords(strings.NewReader(input), func(r Record) error {
		return nil
	})
	if err != nil {
		t.Fatalf("ReadRecords failed on large line: %v", err)
	}
}

func TestReadRecords_NoTrailingNewline(t *testing.T) {
	// Last line without newline should be processed
	input := `{"key_b64":"a2V5MQ==","value_b64":"dmFsdWUx"}`
	var got []Record
	err := ReadRecords(strings.NewReader(input), func(r Record) error {
		got = append(got, r)
		return nil
	})
	if err != nil {
		t.Fatalf("ReadRecords failed without trailing newline: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("ReadRecords count: got %d, want 1", len(got))
	}
}

func TestRecord_BinaryRoundTrip(t *testing.T) {
	testCases := []struct {
		name  string
		key   []byte
		value []byte
	}{
		{
			name:  "simple",
			key:   []byte("simple-key"),
			value: []byte("simple-value"),
		},
		{
			name:  "binary null bytes",
			key:   []byte{0x00, 0x01, 0x02},
			value: []byte{0xFF, 0xFE, 0xFD},
		},
		{
			name:  "binary with slash",
			key:   []byte("/registry/foo"),
			value: []byte("/api/foo"),
		},
		{
			name:  "unicode",
			key:   []byte("ключ"),
			value: []byte("значение"),
		},
		{
			name:  "empty value",
			key:   []byte("key"),
			value: []byte(""),
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			rec := NewRecord(tc.key, tc.value, 1, 1, 1, 0)
			decKey, err := rec.DecodeKey()
			if err != nil {
				t.Fatalf("DecodeKey failed: %v", err)
			}
			if !bytes.Equal(decKey, tc.key) {
				t.Errorf("DecodeKey mismatch: got %v, want %v", decKey, tc.key)
			}

			decValue, err := rec.DecodeValue()
			if err != nil {
				t.Fatalf("DecodeValue failed: %v", err)
			}
			if !bytes.Equal(decValue, tc.value) {
				t.Errorf("DecodeValue mismatch: got %v, want %v", decValue, tc.value)
			}
		})
	}
}

func TestRecord_InvalidBase64Decode(t *testing.T) {
	rec := Record{
		KeyBase64:   "!!!invalid!!!",
		ValueBase64: "valid",
	}
	if _, err := rec.DecodeKey(); err != ErrInvalidKeyBase64 {
		t.Errorf("DecodeKey invalid base64: got %v, want %v", err, ErrInvalidKeyBase64)
	}

	rec = Record{
		KeyBase64:   "valid",
		ValueBase64: "!!!invalid!!!",
	}
	if _, err := rec.DecodeValue(); err != ErrInvalidValueBase64 {
		t.Errorf("DecodeValue invalid base64: got %v, want %v", err, ErrInvalidValueBase64)
	}
}

func TestReadRecords_CollectAll(t *testing.T) {
	input := `{"key_b64":"a2V5MQ==","value_b64":"dmFsdWUx","version":1}` + "\n" +
		`{"key_b64":"a2V5Mg==","value_b64":"dmFsdWUy","version":2}` + "\n"

	var records []Record
	err := ReadRecords(strings.NewReader(input), func(r Record) error {
		records = append(records, r)
		return nil
	})
	if err != nil {
		t.Fatalf("ReadRecords failed: %v", err)
	}
	if len(records) != 2 {
		t.Errorf("records count: got %d, want 2", len(records))
	}
}
