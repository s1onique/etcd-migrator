package etcdsource

import (
	"errors"
	"time"
)

// Config holds parameters for connecting to etcd and dumping a prefix.
type Config struct {
	Endpoints      []string
	Prefix         string
	BatchSize      int64
	DialTimeout    time.Duration
	RequestTimeout time.Duration
}

var (
	ErrMissingEndpoints = errors.New("missing etcd endpoints")
	ErrEmptyPrefix      = errors.New("prefix cannot be empty")
	ErrInvalidBatchSize = errors.New("batch size must be greater than zero")
)

// WithDefaults returns a copy of cfg with zero-valued fields filled in.
func (c Config) WithDefaults() Config {
	out := c
	if out.Prefix == "" {
		out.Prefix = "/registry/"
	}
	if out.BatchSize == 0 {
		out.BatchSize = 1000
	}
	if out.DialTimeout == 0 {
		out.DialTimeout = 5 * time.Second
	}
	if out.RequestTimeout == 0 {
		out.RequestTimeout = 30 * time.Second
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
	return nil
}
