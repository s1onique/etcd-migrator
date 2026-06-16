package kine

import (
	"testing"
)

func TestConfigDefaults(t *testing.T) {
	cfg := Config{}
	if cfg.BatchSize != 0 {
		t.Errorf("expected default BatchSize to be 0, got %d", cfg.BatchSize)
	}
	if cfg.DialTimeout != 0 {
		t.Errorf("expected default DialTimeout to be 0, got %v", cfg.DialTimeout)
	}
	if cfg.RequestTimeout != 0 {
		t.Errorf("expected default RequestTimeout to be 0, got %v", cfg.RequestTimeout)
	}
}
