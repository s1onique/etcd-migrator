package dump

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
)

// ErrMalformedJSON is returned when a JSONL line is not valid JSON.
var ErrMalformedJSON = errors.New("malformed JSON in JSONL line")

// ErrMissingKeyField is returned when a record has an empty or missing key_b64 field.
var ErrMissingKeyField = errors.New("missing key_b64 field in JSONL record")

// ErrMissingValueField is returned when a record has a missing value_b64 field.
// An empty value_b64 ("") is valid; only nil is rejected.
var ErrMissingValueField = errors.New("missing value_b64 field in JSONL record")

// rawRecord is used internally to distinguish missing fields from empty strings.
type rawRecord struct {
	KeyBase64   *string `json:"key_b64"`
	ValueBase64 *string `json:"value_b64"`

	Version        int64 `json:"version"`
	CreateRevision int64 `json:"create_revision"`
	ModRevision    int64 `json:"mod_revision"`
	Lease          int64 `json:"lease"`
}

// WriteRecord writes a single record as a JSON line to w.
func WriteRecord(w io.Writer, r Record) error {
	// Validate required fields before writing
	if r.KeyBase64 == "" {
		return ErrMissingKeyField
	}

	// Use json.Encoder for proper JSON escaping
	enc := json.NewEncoder(w)
	if err := enc.Encode(r); err != nil {
		return err
	}
	return nil
}

// ReadAllRecords reads all JSONL records from r and returns them as a slice.
func ReadAllRecords(r io.Reader) ([]Record, error) {
	var records []Record
	err := ReadRecords(r, func(rec Record) error {
		records = append(records, rec)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return records, nil
}

// ReadRecords reads JSONL records from r, calling visit for each record.
// It processes line-by-line and fails on the first malformed record.
// The visit function may return an error to stop iteration early.
// Binary key/value data in key_b64/value_b64 is not validated at read time.
//
// Large lines (>64 KiB) are supported since this uses bufio.Reader
// instead of bufio.Scanner.
func ReadRecords(r io.Reader, visit func(Record) error) error {
	reader := bufio.NewReader(r)
	lineNum := 0

	for {
		line, err := reader.ReadBytes('\n')
		if err == io.EOF && len(line) == 0 {
			break
		}
		lineNum++

		if err == io.EOF {
			// Process the last line even if it doesn't end with newline
		} else if err != nil {
			return err
		}

		// Remove trailing newline
		if len(line) > 0 && line[len(line)-1] == '\n' {
			line = line[:len(line)-1]
		}

		// Skip empty lines
		if len(line) == 0 {
			continue
		}

		var raw rawRecord
		if err := json.Unmarshal(line, &raw); err != nil {
			return &JSONLError{
				Line:   lineNum,
				Reason: err.Error(),
			}
		}

		// Validate key field - missing or empty key is not allowed
		if raw.KeyBase64 == nil || *raw.KeyBase64 == "" {
			return &JSONLError{
				Line:   lineNum,
				Reason: ErrMissingKeyField.Error(),
			}
		}

		// Validate value field - missing value is not allowed, but empty string is valid
		if raw.ValueBase64 == nil {
			return &JSONLError{
				Line:   lineNum,
				Reason: ErrMissingValueField.Error(),
			}
		}

		// Convert raw to public Record
		rec := Record{
			KeyBase64:      *raw.KeyBase64,
			ValueBase64:    *raw.ValueBase64,
			Version:        raw.Version,
			CreateRevision: raw.CreateRevision,
			ModRevision:    raw.ModRevision,
			Lease:          raw.Lease,
		}

		if err := visit(rec); err != nil {
			return err
		}

		if err == io.EOF {
			break
		}
	}

	return nil
}

// JSONLError represents an error in a JSONL file with line context.
type JSONLError struct {
	Line   int
	Reason string
}

func (e *JSONLError) Error() string {
	return "jsonl: line " + itoa(e.Line) + ": " + e.Reason
}

// itoa converts an int to a string without importing strconv.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var digits []byte
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}
