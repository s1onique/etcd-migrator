package etcdtarget

import (
	"testing"
)

func TestKeyHasPrefix(t *testing.T) {
	tests := []struct {
		name   string
		key    []byte
		prefix string
		want   bool
	}{
		{
			name:   "key matches prefix",
			key:    []byte("/registry/pods/x"),
			prefix: "/registry/",
			want:   true,
		},
		{
			name:   "key is prefix itself",
			key:    []byte("/registry/"),
			prefix: "/registry/",
			want:   true,
		},
		{
			name:   "key shorter than prefix",
			key:    []byte("/registr"),
			prefix: "/registry/",
			want:   false,
		},
		{
			name:   "key does not match prefix",
			key:    []byte("/other/pods/x"),
			prefix: "/registry/",
			want:   false,
		},
		{
			name:   "empty prefix matches nothing",
			key:    []byte("/registry/pods/x"),
			prefix: "",
			want:   false,
		},
		{
			name:   "binary key with prefix bytes passes",
			key:    []byte{0xff, 0xfe, '/', 'r', 'e', 'g', 'i', 's', 't', 'r', 'y', '/'},
			prefix: "/registry/",
			want:   false,
		},
		{
			name:   "binary key matching prefix",
			key:    []byte{0xff, '/', 'r', 'e', 'g', 'i', 's', 't', 'r', 'y', '/'},
			prefix: "/registry/",
			want:   false,
		},
		{
			name:   "key with embedded prefix",
			key:    []byte("/foo/registry/pods"),
			prefix: "/registry/",
			want:   false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := KeyHasPrefix(tt.key, tt.prefix)
			if got != tt.want {
				t.Errorf("KeyHasPrefix(%q, %q) = %v, want %v", string(tt.key), tt.prefix, got, tt.want)
			}
		})
	}
}
