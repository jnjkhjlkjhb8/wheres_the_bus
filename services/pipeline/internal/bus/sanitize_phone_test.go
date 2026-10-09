package bus

import "testing"

func TestSanitizeOperatorPhone(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"clean single", "02-77301777", "02-77301777"},
		{"clean freephone", "0800-090-607", "0800-090-607"},
		// Legit Chinese annotation with no U+FFFD passes through untouched.
		{"clean annotation", "0800-053808(市話)03-3753711", "0800-053808(市話)03-3753711"},
		// TDX mojibake: keep only the recoverable phone runs.
		{"mojibake two numbers", "0800-053808(�ｚ�����)�B03-3753711", "0800-053808 / 03-3753711"},
		{"mojibake all garbage", "���", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := sanitizeOperatorPhone(c.in); got != c.want {
				t.Errorf("sanitizeOperatorPhone(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}
