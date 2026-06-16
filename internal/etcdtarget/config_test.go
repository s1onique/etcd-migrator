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
			expect: Config{Prefix: "/registry/", BatchSize: 100, DialTimeout: 5 * time.Second, RequestTimeout: 30 * time.Second, RequireEmpty: false},
		},
		{
			name: "explicit RequireEmpty=false is preserved",
			cfg: Config{
				Prefix:         "/custom/",
				BatchSize:      50,
				DialTimeout:    10 * time.Second,
				RequestTimeout: 60 * time.Second,
				RequireEmpty:   false,
			},
			expect: Config{
				Prefix:         "/custom/",
				BatchSize:      50,
				DialTimeout:    10 * time.Second,
				RequestTimeout: 60 * time.Second,
				RequireEmpty:   false,
			},
		},
		{
			name: "RequireEmpty=true is preserved",
			cfg: Config{
				Prefix:       "/custom/",
				BatchSize:    50,
				RequireEmpty: true,
			},
			expect: Config{
				Prefix:         "/custom/",
				BatchSize:      50,
				DialTimeout:    5 * time.Second,
				RequestTimeout: 30 * time.Second,
				RequireEmpty:   true,
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
			if got.RequireEmpty != tt.expect.RequireEmpty {
				t.Errorf("RequireEmpty: got %v, want %v", got.RequireEmpty, tt.expect.RequireEmpty)
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
			name:    "valid config",
			cfg:     Config{Endpoints: []string{"http://localhost:2379"}, Prefix: "/registry/", BatchSize: 100},
			wantErr: nil,
		},
		{
			name:    "missing endpoints",
			cfg:     Config{Endpoints: []string{}, Prefix: "/registry/", BatchSize: 100},
			wantErr: ErrMissingEndpoints,
		},
		{
			name:    "empty prefix",
			cfg:     Config{Endpoints: []string{"http://localhost:2379"}, Prefix: "", BatchSize: 100},
			wantErr: ErrEmptyPrefix,
		},
		{
			name:    "zero batch size",
			cfg:     Config{Endpoints: []string{"http://localhost:2379"}, Prefix: "/registry/", BatchSize: 0},
			wantErr: ErrInvalidBatchSize,
		},
		{
			name:    "negative batch size",
			cfg:     Config{Endpoints: []string{"http://localhost:2379"}, Prefix: "/registry/", BatchSize: -1},
			wantErr: ErrInvalidBatchSize,
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
