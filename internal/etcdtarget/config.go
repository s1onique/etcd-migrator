package etcdtarget

import (
	"errors"
	"time"
)

// ConflictPolicy defines behavior when target prefix already contains data.
type ConflictPolicy string

const (
	// PolicyFailIfPresent refuses to write into a non-empty target prefix.
	// This is the safest default for operators.
	PolicyFailIfPresent ConflictPolicy = "fail-if-present"

	// PolicyAllowIdenticalReplay permits a load only when the target prefix
	// exactly matches the dump. Partial targets, divergent values, and extra
	// keys under the prefix fail before mutation.
	PolicyAllowIdenticalReplay ConflictPolicy = "allow-identical-replay"
)

// Config holds parameters for connecting to target etcd and loading a dump.
type Config struct {
	Endpoints      []string
	Prefix         string
	BatchSize      int
	DialTimeout    time.Duration
	RequestTimeout time.Duration
	ConflictPolicy ConflictPolicy
	DumpRecords    []DumpKV // Pre-loaded dump records for identical-replay comparison
}

// DumpKV holds a decoded key/value pair for comparison.
type DumpKV struct {
	Key   []byte
	Value []byte
}

var (
	ErrMissingEndpoints      = errors.New("missing etcd endpoints")
	ErrEmptyPrefix           = errors.New("prefix cannot be empty")
	ErrInvalidBatchSize      = errors.New("batch size must be greater than zero")
	ErrTargetNotEmpty        = errors.New("target prefix is not empty")
	ErrTargetNotIdentical    = errors.New("target prefix does not exactly match dump")
	ErrInvalidConflictPolicy = errors.New("invalid conflict policy")
	ErrEmptyConflictPolicy   = errors.New("conflict policy cannot be empty")
)

// WithDefaults returns a copy of cfg with zero-valued fields filled in.
// Default conflict policy is PolicyFailIfPresent for operator safety.
func (c Config) WithDefaults() Config {
	out := c
	if out.Prefix == "" {
		out.Prefix = "/registry/"
	}
	if out.BatchSize == 0 {
		out.BatchSize = 100
	}
	if out.DialTimeout == 0 {
		out.DialTimeout = 5 * time.Second
	}
	if out.RequestTimeout == 0 {
		out.RequestTimeout = 30 * time.Second
	}
	if out.ConflictPolicy == "" {
		out.ConflictPolicy = PolicyFailIfPresent
	}
	return out
}

// Validate returns an error if cfg is not ready to be used.
func (c Config) Validate() error {
	if len(c.Endpoints) == 0 {
		return ErrMissingEndpoints
	}
	if c.Prefix == "" {
		return ErrEmptyPrefix
	}
	if c.BatchSize <= 0 {
		return ErrInvalidBatchSize
	}
	if c.ConflictPolicy == "" {
		return ErrEmptyConflictPolicy
	}
	if c.ConflictPolicy != PolicyFailIfPresent && c.ConflictPolicy != PolicyAllowIdenticalReplay {
		return ErrInvalidConflictPolicy
	}
	return nil
}

// Stats holds statistics about a successful load operation.
type Stats struct {
	Count  int64
	Bytes  int64
	Prefix string
	Digest string
}
