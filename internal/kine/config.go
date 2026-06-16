// Package kine provides reading from Kine-backed PostgreSQL datastores.
package kine

import (
	"time"
)

// Config holds the configuration for reading from a Kine PostgreSQL source.
type Config struct {
	// DSN is the PostgreSQL connection string.
	// Format: postgres://user:password@host:port/dbname?sslmode=disable
	DSN string

	// Prefix limits the dump to keys starting with this prefix.
	Prefix string

	// BatchSize controls how many rows are fetched per query.
	BatchSize int

	// DialTimeout is the timeout for establishing a PostgreSQL connection.
	DialTimeout time.Duration

	// RequestTimeout is the timeout for each database query.
	RequestTimeout time.Duration
}
