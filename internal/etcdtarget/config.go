package etcdtarget

import (
	"errors"
	"time"
)

// Config holds parameters for connecting to target etcd and loading a dump.
type Config struct {
	Endpoints      []string
	Prefix         string
	BatchSize      int
	DialTimeout    time.Duration
	RequestTimeout time.Duration
	RequireEmpty   bool
}

var (
	ErrMissingEndpoints = errors.New("missing etcd endpoints")
	ErrEmptyPrefix      = errors.New("prefix cannot be empty")
	ErrInvalidBatchSize = errors.New("batch size must be greater than zero")
	ErrTargetNotEmpty   = errors.New("target prefix is not empty")
)

// WithDefaults returns a copy of cfg with zero-valued fields filled in.
// RequireEmpty is NOT defaulted here; callers must set it explicitly.
// The default of true for safety is enforced at CLI/config construction.
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
	// RequireEmpty is intentionally not defaulted here.
	// Callers must set it explicitly based on their safety requirements.
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
	return nil
}

// Stats holds statistics about a successful load operation.
type Stats struct {
	Count  int64
	Bytes  int64
	Prefix string
	Digest string
}
