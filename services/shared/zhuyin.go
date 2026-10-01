package shared

import "strings"

const ZhuyinToneMarks = "ˊˇˋ˙"

// StripZhuyinTones removes the tone marks from a search query so toned input
// matches the toneless aliases the loader writes. A no-op for anything
// without them, which is every query that is not Bopomofo.
func StripZhuyinTones(q string) string {
	if !strings.ContainsAny(q, ZhuyinToneMarks) {
		return q
	}
	return strings.Map(func(r rune) rune {
		if strings.ContainsRune(ZhuyinToneMarks, r) {
			return -1
		}
		return r
	}, q)
}
