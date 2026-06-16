package etcdsource

import (
	"testing"
	"time"
)

func TestConfigWithDefaults(t *testing.T) {
	cfg := Config{}
	d := cfg.WithDefaults()

	if d.Prefix != "/registry/" {
		t.Errorf("default Prefix = %q, want /registry/", d.Prefix)
	}
	if d.BatchSize != 1000 {
		t.Errorf("default BatchSize = %d, want 1000", d.BatchSize)
	}
	if d.DialTimeout != 5*time.Second {
		t.Errorf("default DialTimeout = %v, want 5s", d.DialTimeout)
	}
	if d.RequestTimeout != 30*time.Second {
		t.Errorf("default RequestTimeout = %v, want 30s", d.RequestTimeout)
	}
}

func TestConfigValidate(t *testing.T) {
	tests := []struct {
		name    string
		cfg     Config
		wantErr error
	}{
		{
			name:    "missing endpoints",
			cfg:     Config{Prefix: "/registry/"},
			wantErr: ErrMissingEndpoints,
		},
		{
			name:    "empty prefix",
			cfg:     Config{Endpoints: []string{"http://127.0.0.1:2379"}, Prefix: ""},
			wantErr: ErrEmptyPrefix,
		},
		{
			name:    "zero batch size",
			cfg:     Config{Endpoints: []string{"http://127.0.0.1:2379"}, Prefix: "/registry/", BatchSize: 0},
			wantErr: ErrInvalidBatchSize,
		},
		{
			name:    "negative batch size",
			cfg:     Config{Endpoints: []string{"http://127.0.0.1:2379"}, Prefix: "/registry/", BatchSize: -1},
			wantErr: ErrInvalidBatchSize,
		},
		{
			name:    "valid config",
			cfg:     Config{Endpoints: []string{"http://127.0.0.1:2379"}, Prefix: "/registry/", BatchSize: 1000},
			wantErr: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.cfg.Validate()
			if err != tt.wantErr {
				t.Errorf("Validate() = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

func TestConfigWithDefaultsPreservesExisting(t *testing.T) {
	cfg := Config{
		Prefix:         "/custom/",
		BatchSize:      500,
		DialTimeout:    10 * time.Second,
		RequestTimeout: 60 * time.Second,
	}
	d := cfg.WithDefaults()

	if d.Prefix != "/custom/" {
		t.Errorf("Prefix = %q, want /custom/", d.Prefix)
	}
	if d.BatchSize != 500 {
		t.Errorf("BatchSize = %d, want 500", d.BatchSize)
	}
	if d.DialTimeout != 10*time.Second {
		t.Errorf("DialTimeout = %v, want 10s", d.DialTimeout)
	}
	if d.RequestTimeout != 60*time.Second {
		t.Errorf("RequestTimeout = %v, want 60s", d.RequestTimeout)
	}
}
