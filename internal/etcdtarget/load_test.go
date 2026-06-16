package etcdtarget

import (
	"bytes"
	"strings"
	"testing"

	"github.com/spbnix/etcd-migrator/internal/dump"
)

func TestReadAndValidateDump(t *testing.T) {
	validRecord := dump.NewRecord([]byte("/registry/pods/x"), []byte(`{"apiVersion":"v1"}`), 1, 1, 1, 0)
	validJSON := mustMarshalJSON(t, validRecord)

	tests := []struct {
		name        string
		input       string
		prefix      string
		wantCount   int64
		wantBytes   int64
		wantErr     bool
		errContains string
	}{
		{
			name:      "single valid record",
			input:     validJSON + "\n",
			prefix:    "/registry/",
			wantCount: 1,
			wantBytes: int64(len("/registry/pods/x") + len(`{"apiVersion":"v1"}`)),
		},
		{
			name:      "multiple valid records",
			input:     strings.Repeat(validJSON+"\n", 3),
			prefix:    "/registry/",
			wantCount: 3,
			wantBytes: int64(3 * (len("/registry/pods/x") + len(`{"apiVersion":"v1"}`))),
		},
		{
			name:        "malformed JSON fails before any write",
			input:       `{"key_b64":invalid,"value_b64":""}` + "\n" + validJSON,
			prefix:      "/registry/",
			wantErr:     true,
			errContains: "invalid",
		},
		{
			name:        "invalid base64 in key fails",
			input:       `{"key_b64":"!!!","value_b64":""}` + "\n",
			prefix:      "/registry/",
			wantErr:     true,
			errContains: "key",
		},
		{
			name:        "invalid base64 in value fails",
			input:       mustMarshalJSON(t, dump.NewRecord([]byte("/registry/pods/y"), []byte("valid"), 1, 1, 1, 0)) + "\n" + `{"key_b64":"L2E","value_b64":"!!!"}` + "\n",
			prefix:      "/registry/",
			wantErr:     true,
			errContains: "value_b64",
		},
		{
			name:        "key outside prefix fails",
			input:       validJSON + "\n" + mustMarshalJSON(t, dump.NewRecord([]byte("/other/pods/x"), []byte("v"), 1, 1, 1, 0)),
			prefix:      "/registry/",
			wantErr:     true,
			errContains: "/other/pods/x",
		},
		{
			name:      "key at prefix boundary passes",
			input:     mustMarshalJSON(t, dump.NewRecord([]byte("/registry/"), []byte("v"), 1, 1, 1, 0)) + "\n",
			prefix:    "/registry/",
			wantCount: 1,
			wantBytes: int64(len("/registry/") + len("v")),
		},
		{
			name:      "empty input returns empty",
			input:     "",
			prefix:    "/registry/",
			wantCount: 0,
			wantBytes: 0,
		},
		{
			name:        "missing key_b64 fails",
			input:       `{"value_b64":""}` + "\n",
			prefix:      "/registry/",
			wantErr:     true,
			errContains: "key_b64",
		},
		{
			name:        "missing value_b64 fails",
			input:       `{"key_b64":"L3JlZ2lzdHJ5L3BvZHMveQ=="}` + "\n",
			prefix:      "/registry/",
			wantErr:     true,
			errContains: "value_b64",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := strings.NewReader(tt.input)
			records, count, totalBytes, err := readAndValidateDump(r, tt.prefix)

			if tt.wantErr {
				if err == nil {
					t.Fatalf("readAndValidateDump() error = nil, want error containing %q", tt.errContains)
				}
				if tt.errContains != "" && !strings.Contains(err.Error(), tt.errContains) {
					t.Fatalf("readAndValidateDump() error = %v, want error containing %q", err, tt.errContains)
				}
				return
			}

			if err != nil {
				t.Fatalf("readAndValidateDump() error = %v, want nil", err)
			}
			if count != tt.wantCount {
				t.Errorf("count = %d, want %d", count, tt.wantCount)
			}
			if totalBytes != tt.wantBytes {
				t.Errorf("totalBytes = %d, want %d", totalBytes, tt.wantBytes)
			}
			if int64(len(records)) != tt.wantCount {
				t.Errorf("len(records) = %d, want %d", len(records), tt.wantCount)
			}
		})
	}
}

func TestConflictPolicyConstants(t *testing.T) {
	// Verify policy constants have expected string values.
	if PolicyFailIfPresent != "fail-if-present" {
		t.Errorf("PolicyFailIfPresent = %q, want %q", PolicyFailIfPresent, "fail-if-present")
	}
	if PolicyAllowIdenticalReplay != "allow-identical-replay" {
		t.Errorf("PolicyAllowIdenticalReplay = %q, want %q", PolicyAllowIdenticalReplay, "allow-identical-replay")
	}
}

func TestConfig_ConflictPolicyValues(t *testing.T) {
	// Verify valid policy values.
	validPolicies := []ConflictPolicy{PolicyFailIfPresent, PolicyAllowIdenticalReplay}
	for _, p := range validPolicies {
		cfg := Config{
			Endpoints:      []string{"http://localhost:2379"},
			Prefix:         "/registry/",
			BatchSize:      100,
			ConflictPolicy: p,
		}
		if err := cfg.Validate(); err != nil {
			t.Errorf("Validate() with policy %q = %v, want nil", p, err)
		}
	}

	// Verify invalid policy values fail.
	invalidPolicies := []ConflictPolicy{"", "overwrite", "safe-write", "replace"}
	for _, p := range invalidPolicies {
		cfg := Config{
			Endpoints:      []string{"http://localhost:2379"},
			Prefix:         "/registry/",
			BatchSize:      100,
			ConflictPolicy: p,
		}
		if err := cfg.Validate(); err == nil {
			t.Errorf("Validate() with policy %q = nil, want error", p)
		}
	}
}

func mustMarshalJSON(t *testing.T, rec dump.Record) string {
	t.Helper()
	var buf bytes.Buffer
	if err := dump.WriteRecord(&buf, rec); err != nil {
		t.Fatalf("WriteRecord() error = %v", err)
	}
	return strings.TrimSuffix(buf.String(), "\n")
}
