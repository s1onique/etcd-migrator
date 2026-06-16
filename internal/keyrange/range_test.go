package keyrange

import (
	"bytes"
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
		{
			name:    "short prefix at 0xfe increments to 0xff",
			prefix:  "a\xfe",
			wantEnd: "a\xff",
		},
		{
			name:    "mix of ff bytes handled correctly - increment the byte before",
			prefix:  "abc\xff",
			wantEnd: "abd",
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
			wantBytes := []byte(tt.wantEnd)
			if !bytes.Equal(got, wantBytes) {
				t.Errorf("PrefixRangeEnd(%q) = %q, want %q", tt.prefix, string(got), tt.wantEnd)
			}
		})
	}
}

func TestPrefixRangeEndString(t *testing.T) {
	tests := []struct {
		prefix string
		want   string
	}{
		{"/registry/", "/registry0"},
	}

	for _, tt := range tests {
		t.Run(tt.prefix, func(t *testing.T) {
			got := PrefixRangeEndString(tt.prefix)
			if got != tt.want {
				t.Errorf("PrefixRangeEndString(%q) = %q, want %q", tt.prefix, got, tt.want)
			}
		})
	}
}

func TestNextKeyAfter(t *testing.T) {
	tests := []struct {
		key  string
		want string
	}{
		{"/registry/", "/registry/\x00"},
		{"a", "a\x00"},
		{"", "\x00"},
		{"\xff", "\xff\x00"},
	}

	for _, tt := range tests {
		t.Run(tt.key, func(t *testing.T) {
			got := NextKeyAfter([]byte(tt.key))
			want := []byte(tt.want)
			if !bytes.Equal(got, want) {
				t.Errorf("NextKeyAfter(%q) = %q, want %q", tt.key, string(got), tt.want)
			}
		})
	}
}

func TestShouldContinue(t *testing.T) {
	tests := []struct {
		start    string
		rangeEnd string
		want     bool
	}{
		{"a", "b", true},
		{"a", "a", false},
		{"b", "a", false},
		{"", "", false},
		{"a", "", false},
		{"\xff", "\xff", false},
		{"\xff", "\xff\x00", true},
		{"/registry/", "/registry0", true},
		{"/registry0", "/registry0", false},
	}

	for _, tt := range tests {
		t.Run(tt.start+"_"+tt.rangeEnd, func(t *testing.T) {
			got := ShouldContinue([]byte(tt.start), []byte(tt.rangeEnd))
			if got != tt.want {
				t.Errorf("ShouldContinue(%q, %q) = %v, want %v", tt.start, tt.rangeEnd, got, tt.want)
			}
		})
	}
}
