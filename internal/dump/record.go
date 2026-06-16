package dump

import (
	"encoding/base64"
	"errors"
)

// Record represents a single key/value pair from an etcd snapshot.
// Metadata (version, revisions, lease) is recorded but not restored.
type Record struct {
	KeyBase64   string `json:"key_b64"`
	ValueBase64 string `json:"value_b64"`

	Version        int64 `json:"version"`
	CreateRevision int64 `json:"create_revision"`
	ModRevision    int64 `json:"mod_revision"`
	Lease          int64 `json:"lease"`
}

var (
	ErrInvalidKeyBase64   = errors.New("invalid base64 in key_b64 field")
	ErrInvalidValueBase64 = errors.New("invalid base64 in value_b64 field")
)

// NewRecord creates a Record with the given key/value bytes and metadata.
// The key and value are base64-encoded for JSONL storage.
func NewRecord(key, value []byte, version, createRevision, modRevision, lease int64) Record {
	return Record{
		KeyBase64:      base64.RawStdEncoding.EncodeToString(key),
		ValueBase64:    base64.RawStdEncoding.EncodeToString(value),
		Version:        version,
		CreateRevision: createRevision,
		ModRevision:    modRevision,
		Lease:          lease,
	}
}

// DecodeKey decodes the base64-encoded key back to raw bytes.
func (r Record) DecodeKey() ([]byte, error) {
	data, err := base64.RawStdEncoding.DecodeString(r.KeyBase64)
	if err != nil {
		return nil, ErrInvalidKeyBase64
	}
	return data, nil
}

// DecodeValue decodes the base64-encoded value back to raw bytes.
func (r Record) DecodeValue() ([]byte, error) {
	data, err := base64.RawStdEncoding.DecodeString(r.ValueBase64)
	if err != nil {
		return nil, ErrInvalidValueBase64
	}
	return data, nil
}
