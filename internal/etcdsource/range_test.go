package etcdsource

import (
	"testing"
)

func TestPrefixRangeEnd(t *testing.T) {
	tests := []struct {
		name    string
		prefix  string
		wantEnd string
		wantNil bool
	}{
		{
			name:    "registry slash",
			prefix:  "/registry/",
			wantEnd: "/registry0",
		},
		{
			name:    "simple a",
			prefix:  "a",
			wantEnd: "b",
		},
		{
			name:    "az increments last byte",
			prefix:  "az",
			wantEnd: "a{",
		},
		{
			name:    "abc slash increments slash to zero",
			prefix:  "abc/",
			wantEnd: "abc0",
		},
		{
			name:    "all ff returns nil",
			prefix:  "\xff\xff",
			wantNil: true,
		},
		{
			name:    "single ff returns nil",
			prefix:  "\xff",
			wantNil: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := PrefixRangeEnd([]byte(tt.prefix))
			if tt.wantNil {
				if got != nil {
					t.Errorf("PrefixRangeEnd(%q) = %v, want nil", tt.prefix, got)
				}
				return
			}
			if string(got) != tt.wantEnd {
				t.Errorf("PrefixRangeEnd(%q) = %q, want %q", tt.prefix, got, tt.wantEnd)
			}
		})
	}
}

func TestNextKeyAfter(t *testing.T) {
	// Ensure original slice is not mutated
	orig := []byte("abc")
	out := NextKeyAfter(orig)
	if string(orig) != "abc" {
		t.Errorf("NextKeyAfter mutated input: got %q, want %q", orig, "abc")
	}
	if string(out) != "abc\x00" {
		t.Errorf("NextKeyAfter(%q) = %q, want %q", "abc", out, "abc\x00")
	}
}

func TestPrefixRangeEndString(t *testing.T) {
	got := PrefixRangeEndString("/registry/")
	if got != "/registry0" {
		t.Errorf("PrefixRangeEndString(/registry/) = %q, want /registry0", got)
	}
}

func TestPrefixRangeEndEdgeCases(t *testing.T) {
	// Empty prefix returns nil
	if r := PrefixRangeEnd([]byte{}); r != nil {
		t.Errorf("PrefixRangeEnd([]) = %v, want nil", r)
	}

	// Short prefix at 0xfe increments to 0xff
	if r := PrefixRangeEnd([]byte("a\xfe")); string(r) != "a\xff" {
		t.Errorf("PrefixRangeEnd(a\\xfe) = %q, want a\\xff", r)
	}

	// Mix of ff bytes handled correctly - increment the byte before
	if r := PrefixRangeEnd([]byte("abc\xff")); string(r) != "abd" {
		t.Errorf("PrefixRangeEnd(abc\\xff) = %q, want abd", r)
	}
}

func TestShouldContinue(t *testing.T) {
	tests := []struct {
		name     string
		startKey []byte
		rangeEnd []byte
		want     bool
	}{
		{
			name:     "start before end",
			startKey: []byte("a"),
			rangeEnd: []byte("b"),
			want:     true,
		},
		{
			name:     "start equals end",
			startKey: []byte("a"),
			rangeEnd: []byte("a"),
			want:     false,
		},
		{
			name:     "start after end",
			startKey: []byte("b"),
			rangeEnd: []byte("a"),
			want:     false,
		},
		{
			name:     "binary key with nul before range end",
			startKey: []byte("abc\x00"),
			rangeEnd: []byte("abc\x01"),
			want:     true,
		},
		{
			name:     "binary key with nul at range end",
			startKey: []byte("abc\x00"),
			rangeEnd: []byte("abc\x00"),
			want:     false,
		},
		{
			name:     "binary key with ff",
			startKey: []byte("abc\xff"),
			rangeEnd: []byte("abd"),
			want:     true,
		},
		{
			name:     "key with embedded nul comparing against string",
			startKey: []byte("a\x00b"),
			rangeEnd: []byte("a\x00c"),
			want:     true,
		},
		{
			name:     "key containing 0xff bytes",
			startKey: []byte("\xff\xff"),
			rangeEnd: []byte("\xff\xff\x00"),
			want:     true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ShouldContinue(tt.startKey, tt.rangeEnd)
			if got != tt.want {
				t.Errorf("ShouldContinue(%v, %v) = %v, want %v",
					tt.startKey, tt.rangeEnd, got, tt.want)
			}
		})
	}
}
