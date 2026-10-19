package searchalias

import (
	"strings"
	"unicode"

	"github.com/mozillazg/go-pinyin"
)

func SearchAlias(name string) string {
	syllables := pinyinSyllables(name)
	if len(syllables) == 0 {
		return strings.Join(nameShorthands(name), " ")
	}

	forms := []string{joinSyllables(syllables, func(s string) string { return s })}
	// Initials are only a useful handle when there is more than one syllable;
	// for a one-syllable name they are a single letter that matches half the
	// corpus.
	if len(syllables) > 1 {
		forms = append(forms, joinSyllables(syllables, syllableInitial))
	}
	if z := joinSyllables(syllables, syllableZhuyin); z != "" {
		forms = append(forms, z)
	}
	forms = append(forms, nameShorthands(name)...)
	return strings.Join(forms, " ")
}

func joinSyllables(syllables []string, convert func(string) string) string {
	var result strings.Builder
	for _, syllable := range syllables {
		result.WriteString(convert(syllable))
	}
	return result.String()
}

func pinyinSyllables(name string) []string {
	args := pinyin.NewArgs()
	var out []string
	for _, r := range name {
		if syllable := runePinyin(r, args); syllable != "" {
			out = append(out, syllable)
		}
	}
	return out
}

func runePinyin(r rune, args pinyin.Args) string {
	if readings := pinyin.SinglePinyin(r, args); len(readings) > 0 {
		return readings[0]
	}
	if unicode.IsLetter(r) || unicode.IsDigit(r) {
		return strings.ToLower(string(r))
	}
	return ""
}

// syllableInitial is the first letter of a romanised syllable — the handle a
// rider uses when they type "bt" for 北投. Digits and Latin runes carried
// through by pinyinSyllables are their own initial.
func syllableInitial(syllable string) string {
	if syllable == "" {
		return ""
	}
	return syllable[:1]
}

var _nameShorthandTable = map[string][]string{
	"臺北車站":  {"北車"},
	"台北車站":  {"北車"},
	"臺北市政府": {"市府"},
	"台北市政府": {"市府"},
	"市政府":   {"市府"},
	"高雄車站":  {"高雄火車站"},
	"臺中車站":  {"台中火車站"},
	"台中車站":  {"台中火車站"},
}

func nameShorthands(name string) []string {
	return _nameShorthandTable[name]
}
