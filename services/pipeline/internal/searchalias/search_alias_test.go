package searchalias

import (
	"strings"
	"testing"
)

func TestSearchAliasCoversHowRidersType(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  []string
	}{
		{
			name:  "station name yields full pinyin, initials, and bopomofo",
			input: "北投",
			want:  []string{"beitou", "bt", "ㄅㄟㄊㄡ"},
		},
		{
			name:  "hand-listed shorthand is carried alongside the readings",
			input: "臺北車站",
			want:  []string{"taibeichezhan", "tbcz", "北車"},
		},
		{
			name:  "digits stay where they are instead of being dropped",
			input: "紅5",
			want:  []string{"hong5"},
		},
		{
			name:  "latin runes are lower-cased and kept",
			input: "YouBike",
			want:  []string{"youbike"},
		},
		{
			name:  "empty rime is not spelled with ㄧ",
			input: "士林",
			want:  []string{"shilin", "ㄕㄌㄧㄣ"},
		},
		{
			name:  "zero-initial syllables use their i/u/ü forms",
			input: "永安",
			want:  []string{"yongan", "ㄩㄥㄢ"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := SearchAlias(tt.input)
			for _, want := range tt.want {
				if !strings.Contains(got, want) {
					t.Errorf("SearchAlias(%q) = %q, want it to contain %q", tt.input, got, want)
				}
			}
		})
	}
}

// A one-syllable name's initial is a single letter that would match a large
// share of the corpus, so it is deliberately left out.
func TestSearchAliasOmitsSingleSyllableInitials(t *testing.T) {
	got := strings.Fields(SearchAlias("橋"))
	for _, form := range got {
		if form == "q" {
			t.Fatalf("SearchAlias(%q) = %v, want no bare initial", "橋", got)
		}
	}
}

// A name with no readable rune at all must not produce a stray separator that
// would make the column look populated when it holds nothing.
func TestSearchAliasIsEmptyWithoutReadings(t *testing.T) {
	if got := SearchAlias("—"); got != "" {
		t.Errorf("SearchAlias(%q) = %q, want empty", "—", got)
	}
}

func TestSyllableZhuyin(t *testing.T) {
	tests := []struct {
		syllable string
		want     string
	}{
		{"bei", "ㄅㄟ"},
		{"tou", "ㄊㄡ"},
		{"shi", "ㄕ"},
		{"zhi", "ㄓ"},
		{"si", "ㄙ"},
		// sh+an, not s+han.
		{"shan", "ㄕㄢ"},
		{"jiu", "ㄐㄧㄡ"},
		{"gui", "ㄍㄨㄟ"},
		{"lun", "ㄌㄨㄣ"},
		{"zhong", "ㄓㄨㄥ"},
		// ju/qu/xu spell ü as u.
		{"ju", "ㄐㄩ"},
		{"xue", "ㄒㄩㄝ"},
		{"quan", "ㄑㄩㄢ"},
		{"lv", "ㄌㄩ"},
		{"yi", "ㄧ"},
		{"wang", "ㄨㄤ"},
		{"yuan", "ㄩㄢ"},
		{"er", "ㄦ"},
		// Not pinyin: carried-through digits and Latin have no reading.
		{"5", ""},
		{"", ""},
	}

	for _, tt := range tests {
		t.Run(tt.syllable, func(t *testing.T) {
			if got := syllableZhuyin(tt.syllable); got != tt.want {
				t.Errorf("syllableZhuyin(%q) = %q, want %q", tt.syllable, got, tt.want)
			}
		})
	}
}
