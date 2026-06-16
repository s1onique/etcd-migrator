package etcdsource

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/spbnix/etcd-migrator/internal/dump"
	"go.etcd.io/etcd/client/v3"
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

// NewClient creates a new etcd client configured from cfg.
func NewClient(ctx context.Context, cfg Config) (*clientv3.Client, error) {
	cfg = cfg.WithDefaults()
	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	cli, err := clientv3.New(clientv3.Config{
		Endpoints:   cfg.Endpoints,
		DialTimeout: cfg.DialTimeout,
	})
	if err != nil {
		return nil, err
	}

	return cli, nil
}

// FetchAllRecords reads all records from an etcd cluster under cfg.Prefix.
func FetchAllRecords(ctx context.Context, cli *clientv3.Client, cfg Config) ([]dump.Record, error) {
	cfg = cfg.WithDefaults()

	startKey := []byte(cfg.Prefix)
	rangeEnd := PrefixRangeEnd(startKey)
	if rangeEnd == nil {
		return nil, fmt.Errorf("etcd source: prefix %q cannot be bounded", cfg.Prefix)
	}

	var records []dump.Record
	currentKey := startKey

	for {
		var getOpts []clientv3.OpOption
		getOpts = append(getOpts,
			clientv3.WithRange(string(rangeEnd)),
			clientv3.WithSort(clientv3.SortByKey, clientv3.SortAscend),
			clientv3.WithLimit(cfg.BatchSize),
		)

		pageCtx, cancel := context.WithTimeout(ctx, cfg.RequestTimeout)
		resp, err := cli.Get(pageCtx, string(currentKey), getOpts...)
		cancel()
		if err != nil {
			return nil, err
		}

		if len(resp.Kvs) == 0 {
			break
		}

		for _, kv := range resp.Kvs {
			rec := dump.NewRecord(kv.Key, kv.Value,
				kv.Version, kv.CreateRevision, kv.ModRevision, kv.Lease)
			records = append(records, rec)
		}

		lastKey := resp.Kvs[len(resp.Kvs)-1].Key
		currentKey = NextKeyAfter(lastKey)
		if !ShouldContinue(currentKey, rangeEnd) {
			break
		}
	}

	return records, nil
}
