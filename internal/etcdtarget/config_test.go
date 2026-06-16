package etcdtarget

import (
	"testing"
	"time"
)

func TestConfig_WithDefaults(t *testing.T) {
	tests := []struct {
		name   string
		cfg    Config
		expect Config
	}{
		{
			name:   "empty config gets all defaults",
			cfg:    Config{},
			expect: Config{Prefix: "/registry/", BatchSize: 100, DialTimeout: 5 * time.Second, RequestTimeout: 30 * time.Second, ConflictPolicy: PolicyFailIfPresent},
		},
		{
			name: "explicit fail-if-present is preserved",
			cfg: Config{
				Prefix:         "/custom/",
				BatchSize:      50,
				DialTimeout:    10 * time.Second,
				ConflictPolicy: PolicyFailIfPresent,
			},
			expect: Config{
				Prefix:         "/custom/",
				BatchSize:      50,
				DialTimeout:    10 * time.Second,
				RequestTimeout: 30 * time.Second,
				ConflictPolicy: PolicyFailIfPresent,
			},
		},
		{
			name: "allow-identical-replay is preserved",
			cfg: Config{
				Prefix:         "/custom/",
				BatchSize:      50,
				ConflictPolicy: PolicyAllowIdenticalReplay,
			},
			expect: Config{
				Prefix:         "/custom/",
				BatchSize:      50,
				DialTimeout:    5 * time.Second,
				RequestTimeout: 30 * time.Second,
				ConflictPolicy: PolicyAllowIdenticalReplay,
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.cfg.WithDefaults()
			if got.Prefix != tt.expect.Prefix {
				t.Errorf("Prefix: got %q, want %q", got.Prefix, tt.expect.Prefix)
			}
			if got.BatchSize != tt.expect.BatchSize {
				t.Errorf("BatchSize: got %d, want %d", got.BatchSize, tt.expect.BatchSize)
			}
			if got.DialTimeout != tt.expect.DialTimeout {
				t.Errorf("DialTimeout: got %v, want %v", got.DialTimeout, tt.expect.DialTimeout)
			}
			if got.RequestTimeout != tt.expect.RequestTimeout {
				t.Errorf("RequestTimeout: got %v, want %v", got.RequestTimeout, tt.expect.RequestTimeout)
			}
			if got.ConflictPolicy != tt.expect.ConflictPolicy {
				t.Errorf("ConflictPolicy: got %v, want %v", got.ConflictPolicy, tt.expect.ConflictPolicy)
			}
		})
	}
}

func TestConfig_Validate(t *testing.T) {
	tests := []struct {
		name    string
		cfg     Config
		wantErr error
	}{
		{
			name:    "valid config with fail-if-present",
			cfg:     Config{Endpoints: []string{"http://localhost:2379"}, Prefix: "/registry/", BatchSize: 100, ConflictPolicy: PolicyFailIfPresent},
			wantErr: nil,
		},
		{
			name:    "valid config with allow-identical-replay",
			cfg:     Config{Endpoints: []string{"http://localhost:2379"}, Prefix: "/registry/", BatchSize: 100, ConflictPolicy: PolicyAllowIdenticalReplay},
			wantErr: nil,
		},
		{
			name:    "missing endpoints",
			cfg:     Config{Endpoints: []string{}, Prefix: "/registry/", BatchSize: 100, ConflictPolicy: PolicyFailIfPresent},
			wantErr: ErrMissingEndpoints,
		},
		{
			name:    "empty prefix",
			cfg:     Config{Endpoints: []string{"http://localhost:2379"}, Prefix: "", BatchSize: 100, ConflictPolicy: PolicyFailIfPresent},
			wantErr: ErrEmptyPrefix,
		},
		{
			name:    "zero batch size",
			cfg:     Config{Endpoints: []string{"http://localhost:2379"}, Prefix: "/registry/", BatchSize: 0, ConflictPolicy: PolicyFailIfPresent},
			wantErr: ErrInvalidBatchSize,
		},
		{
			name:    "negative batch size",
			cfg:     Config{Endpoints: []string{"http://localhost:2379"}, Prefix: "/registry/", BatchSize: -1, ConflictPolicy: PolicyFailIfPresent},
			wantErr: ErrInvalidBatchSize,
		},
		{
			name:    "empty conflict policy",
			cfg:     Config{Endpoints: []string{"http://localhost:2379"}, Prefix: "/registry/", BatchSize: 100, ConflictPolicy: ""},
			wantErr: ErrEmptyConflictPolicy,
		},
		{
			name:    "invalid conflict policy",
			cfg:     Config{Endpoints: []string{"http://localhost:2379"}, Prefix: "/registry/", BatchSize: 100, ConflictPolicy: "overwrite"},
			wantErr: ErrInvalidConflictPolicy,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.cfg.Validate()
			if err != tt.wantErr {
				t.Errorf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}
