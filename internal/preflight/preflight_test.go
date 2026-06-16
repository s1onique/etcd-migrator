package preflight

import (
	"encoding/json"
	"testing"
	"time"
)

func TestReportClassifyWithKVComparison(t *testing.T) {
	tests := []struct {
		name               string
		sourceKVs          map[string][]byte
		targetKVs          map[string][]byte
		conflictPolicy     string
		wantClassification ResultClassification
		wantGoNoGo         bool
	}{
		{
			name: "fresh import - source has keys, target empty",
			sourceKVs: map[string][]byte{
				"/registry/a": []byte("value1"),
			},
			targetKVs:          map[string][]byte{},
			conflictPolicy:     "fail-if-present",
			wantClassification: ClassificationFreshImport,
			wantGoNoGo:         true,
		},
		{
			name:               "empty source",
			sourceKVs:          map[string][]byte{},
			targetKVs:          map[string][]byte{},
			conflictPolicy:     "fail-if-present",
			wantClassification: ClassificationEmptySource,
			wantGoNoGo:         false,
		},
		{
			name: "identical replay with allow-identical-replay",
			sourceKVs: map[string][]byte{
				"/registry/a": []byte("value1"),
				"/registry/b": []byte("value2"),
			},
			targetKVs: map[string][]byte{
				"/registry/a": []byte("value1"),
				"/registry/b": []byte("value2"),
			},
			conflictPolicy:     "allow-identical-replay",
			wantClassification: ClassificationIdenticalReplay,
			wantGoNoGo:         true,
		},
		{
			name: "conflict - different values with allow-identical-replay",
			sourceKVs: map[string][]byte{
				"/registry/a": []byte("value1"),
			},
			targetKVs: map[string][]byte{
				"/registry/a": []byte("different"),
			},
			conflictPolicy:     "allow-identical-replay",
			wantClassification: ClassificationConflict,
			wantGoNoGo:         false,
		},
		{
			name: "conflict - different key count",
			sourceKVs: map[string][]byte{
				"/registry/a": []byte("value1"),
			},
			targetKVs: map[string][]byte{
				"/registry/a": []byte("value1"),
				"/registry/b": []byte("value2"),
			},
			conflictPolicy:     "fail-if-present",
			wantClassification: ClassificationConflict,
			wantGoNoGo:         false,
		},
		{
			name: "conflict - target has extra keys",
			sourceKVs: map[string][]byte{
				"/registry/a": []byte("value1"),
			},
			targetKVs: map[string][]byte{
				"/registry/a": []byte("value1"),
				"/registry/b": []byte("value2"),
			},
			conflictPolicy:     "allow-identical-replay",
			wantClassification: ClassificationConflict,
			wantGoNoGo:         false,
		},
		{
			name: "conflict - fail-if-present with same keys",
			sourceKVs: map[string][]byte{
				"/registry/a": []byte("value1"),
			},
			targetKVs: map[string][]byte{
				"/registry/a": []byte("value1"),
			},
			conflictPolicy:     "fail-if-present",
			wantClassification: ClassificationConflict,
			wantGoNoGo:         false,
		},
		// Note: Keys outside prefix are filtered by fetchPrefixKVs before comparison.
		// The classifyWithKVComparison function only sees keys under the prefix.
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			report := &Report{
				ConflictPolicy: tt.conflictPolicy,
			}
			report.classifyWithKVComparison(tt.sourceKVs, tt.targetKVs)

			if report.Classification != tt.wantClassification {
				t.Errorf("classifyWithKVComparison() classification = %v, want %v", report.Classification, tt.wantClassification)
			}
			if report.GoNoGo != tt.wantGoNoGo {
				t.Errorf("classifyWithKVComparison() goNoGo = %v, want %v", report.GoNoGo, tt.wantGoNoGo)
			}
		})
	}
}

func TestCompareKVs(t *testing.T) {
	tests := []struct {
		name string
		a    map[string][]byte
		b    map[string][]byte
		want bool
	}{
		{
			name: "identical",
			a: map[string][]byte{
				"key1": []byte("value1"),
			},
			b: map[string][]byte{
				"key1": []byte("value1"),
			},
			want: true,
		},
		{
			name: "different values",
			a: map[string][]byte{
				"key1": []byte("value1"),
			},
			b: map[string][]byte{
				"key1": []byte("value2"),
			},
			want: false,
		},
		{
			name: "different key count",
			a: map[string][]byte{
				"key1": []byte("value1"),
			},
			b: map[string][]byte{
				"key1": []byte("value1"),
				"key2": []byte("value2"),
			},
			want: false,
		},
		{
			name: "missing key in b",
			a: map[string][]byte{
				"key1": []byte("value1"),
				"key2": []byte("value2"),
			},
			b: map[string][]byte{
				"key1": []byte("value1"),
			},
			want: false,
		},
		{
			name: "both empty",
			a:    map[string][]byte{},
			b:    map[string][]byte{},
			want: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := compareKVs(tt.a, tt.b)
			if got != tt.want {
				t.Errorf("compareKVs() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestReportToJSON(t *testing.T) {
	report := &Report{
		GoNoGo:               true,
		Classification:       ClassificationFreshImport,
		SourceEndpoint:       EndpointInfo{Endpoints: []string{"localhost:2379"}, Healthy: true, Version: "3.5.0"},
		TargetEndpoint:       EndpointInfo{Endpoints: []string{"localhost:2379"}, Healthy: true, Version: "3.5.0"},
		Prefix:               "/registry/",
		ConflictPolicy:       "fail-if-present",
		SourcePrefixKeyCount: 100,
		TargetPrefixKeyCount: 0,
		ToolVersion:          "0.1.0",
		Timestamp:            time.Date(2026, 6, 16, 12, 0, 0, 0, time.UTC),
	}

	data, err := report.ToJSON()
	if err != nil {
		t.Fatalf("ToJSON() error = %v", err)
	}

	var parsed map[string]interface{}
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("ToJSON() produced invalid JSON: %v", err)
	}

	fields := []string{
		"go_no_go",
		"classification",
		"source_endpoint",
		"target_endpoint",
		"prefix",
		"conflict_policy",
		"source_prefix_key_count",
		"target_prefix_key_count",
		"tool_version",
		"timestamp",
	}
	for _, field := range fields {
		if _, ok := parsed[field]; !ok {
			t.Errorf("ToJSON() missing field %q", field)
		}
	}
}

func TestReportToText(t *testing.T) {
	report := &Report{
		GoNoGo:               true,
		Classification:       ClassificationFreshImport,
		SourceEndpoint:       EndpointInfo{Endpoints: []string{"localhost:2379"}, Healthy: true, Version: "3.5.0"},
		TargetEndpoint:       EndpointInfo{Endpoints: []string{"localhost:2380"}, Healthy: true, Version: "3.5.0"},
		Prefix:               "/registry/",
		ConflictPolicy:       "fail-if-present",
		SourcePrefixKeyCount: 100,
		TargetPrefixKeyCount: 0,
		ToolVersion:          "0.1.0",
		Timestamp:            time.Date(2026, 6, 16, 12, 0, 0, 0, time.UTC),
	}

	text := report.ToText()

	sections := []string{
		"etcd-migrator preflight report",
		"tool version:",
		"source endpoint",
		"target endpoint",
		"migration parameters",
		"prefix key counts",
		"result",
		"go/no-go:",
		"classification:",
	}
	for _, section := range sections {
		if !containsString(text, section) {
			t.Errorf("ToText() missing section %q", section)
		}
	}
}

func TestPreflightConfigWithDefaults(t *testing.T) {
	cfg := PreflightConfig{}
	cfg = cfg.WithDefaults()

	if cfg.DialTimeout != 5*time.Second {
		t.Errorf("WithDefaults() dialTimeout = %v, want 5s", cfg.DialTimeout)
	}
	if cfg.RequestTimeout != 30*time.Second {
		t.Errorf("WithDefaults() requestTimeout = %v, want 30s", cfg.RequestTimeout)
	}
	if cfg.ConflictPolicy != "fail-if-present" {
		t.Errorf("WithDefaults() conflictPolicy = %v, want fail-if-present", cfg.ConflictPolicy)
	}
}

func TestPreflightConfigValidate(t *testing.T) {
	tests := []struct {
		name    string
		cfg     PreflightConfig
		wantErr bool
	}{
		{
			name: "valid config",
			cfg: PreflightConfig{
				SourceEndpoints: []string{"localhost:2379"},
				TargetEndpoints: []string{"localhost:2380"},
				Prefix:          "/registry/",
				ConflictPolicy:  "fail-if-present",
			},
			wantErr: false,
		},
		{
			name: "valid config with allow-identical-replay",
			cfg: PreflightConfig{
				SourceEndpoints: []string{"localhost:2379"},
				TargetEndpoints: []string{"localhost:2380"},
				Prefix:          "/registry/",
				ConflictPolicy:  "allow-identical-replay",
			},
			wantErr: false,
		},
		{
			name: "missing source endpoints",
			cfg: PreflightConfig{
				TargetEndpoints: []string{"localhost:2380"},
				Prefix:          "/registry/",
				ConflictPolicy:  "fail-if-present",
			},
			wantErr: true,
		},
		{
			name: "missing target endpoints",
			cfg: PreflightConfig{
				SourceEndpoints: []string{"localhost:2379"},
				Prefix:          "/registry/",
				ConflictPolicy:  "fail-if-present",
			},
			wantErr: true,
		},
		{
			name: "empty prefix",
			cfg: PreflightConfig{
				SourceEndpoints: []string{"localhost:2379"},
				TargetEndpoints: []string{"localhost:2380"},
				Prefix:          "",
				ConflictPolicy:  "fail-if-present",
			},
			wantErr: true,
		},
		{
			name: "invalid conflict policy",
			cfg: PreflightConfig{
				SourceEndpoints: []string{"localhost:2379"},
				TargetEndpoints: []string{"localhost:2380"},
				Prefix:          "/registry/",
				ConflictPolicy:  "overwrite",
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.cfg.Validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestResultClassificationValues(t *testing.T) {
	classifications := []ResultClassification{
		ClassificationFreshImport,
		ClassificationIdenticalReplay,
		ClassificationConflict,
		ClassificationEmptySource,
		ClassificationUnhealthySource,
		ClassificationUnhealthyTarget,
		ClassificationInvalidPrefix,
		ClassificationUnknown,
	}

	seen := make(map[ResultClassification]bool)
	for _, c := range classifications {
		if c == "" {
			t.Errorf("classification constant is empty")
		}
		if seen[c] {
			t.Errorf("duplicate classification constant: %v", c)
		}
		seen[c] = true
	}
}

func containsString(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(substr) == 0 ||
		(len(s) > 0 && len(substr) > 0 && findSubstring(s, substr)))
}

func findSubstring(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
