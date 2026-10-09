package shared

import "testing"

func TestStripZhuyinTones(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{name: "toned bopomofo", input: "ㄅㄟˇㄊㄡˊ", want: "ㄅㄟㄊㄡ"},
		{name: "neutral tone", input: "˙ㄉㄜ", want: "ㄉㄜ"},
		{name: "untoned input is returned as is", input: "北投", want: "北投"},
		{name: "latin is untouched", input: "beitou", want: "beitou"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := StripZhuyinTones(tt.input); got != tt.want {
				t.Errorf("StripZhuyinTones(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}
