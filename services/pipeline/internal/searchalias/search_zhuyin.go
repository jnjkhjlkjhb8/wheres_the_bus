package searchalias

import "strings"

func syllableZhuyin(syllable string) string {
	if syllable == "" {
		return ""
	}
	if z, ok := _zhuyinWholeSyllable[syllable]; ok {
		return z
	}
	initial, final := splitPinyinSyllable(syllable)
	// ju/que/xuan spell ü as a plain u — there is no j/q/x syllable with a
	// true /u/, so the rewrite is unambiguous. Only a leading u is the ü:
	// the u in jiu belongs to the final ㄧㄡ.
	if strings.HasPrefix(final, "u") &&
		(initial == "j" || initial == "q" || initial == "x") {
		final = "v" + final[len("u"):]
	}
	zi, iok := _zhuyinInitial[initial]
	zf, fok := _zhuyinFinal[final]
	if !iok || !fok {
		return ""
	}
	return zi + zf
}

// splitPinyinSyllable takes the longest initial that leaves a non-empty
// final. Longest-first matters for the two-letter initials: "shan" is sh+an,
// not s+han.
func splitPinyinSyllable(syllable string) (initial, final string) {
	for _, candidate := range _zhuyinInitialsByLength {
		if len(syllable) > len(candidate) && strings.HasPrefix(syllable, candidate) {
			return candidate, syllable[len(candidate):]
		}
	}
	return "", syllable
}

// _zhuyinInitialsByLength lists the initials two-letter-first so
// splitPinyinSyllable's longest match is the first hit.
var _zhuyinInitialsByLength = []string{
	"zh", "ch", "sh",
	"b", "p", "m", "f", "d", "t", "n", "l",
	"g", "k", "h", "j", "q", "x", "r", "z", "c", "s",
}

var _zhuyinInitial = map[string]string{
	"":   "",
	"b":  "ㄅ",
	"p":  "ㄆ",
	"m":  "ㄇ",
	"f":  "ㄈ",
	"d":  "ㄉ",
	"t":  "ㄊ",
	"n":  "ㄋ",
	"l":  "ㄌ",
	"g":  "ㄍ",
	"k":  "ㄎ",
	"h":  "ㄏ",
	"j":  "ㄐ",
	"q":  "ㄑ",
	"x":  "ㄒ",
	"zh": "ㄓ",
	"ch": "ㄔ",
	"sh": "ㄕ",
	"r":  "ㄖ",
	"z":  "ㄗ",
	"c":  "ㄘ",
	"s":  "ㄙ",
}

// _zhuyinFinal covers the finals as they are spelled after an initial,
// including the contracted spellings (iu for iou, ui for uei, un for uen)
// that pinyin uses only in that position.
var _zhuyinFinal = map[string]string{
	"a":    "ㄚ",
	"o":    "ㄛ",
	"e":    "ㄜ",
	"ê":    "ㄝ",
	"ai":   "ㄞ",
	"ei":   "ㄟ",
	"ao":   "ㄠ",
	"ou":   "ㄡ",
	"an":   "ㄢ",
	"en":   "ㄣ",
	"ang":  "ㄤ",
	"eng":  "ㄥ",
	"er":   "ㄦ",
	"i":    "ㄧ",
	"ia":   "ㄧㄚ",
	"io":   "ㄧㄛ",
	"ie":   "ㄧㄝ",
	"iai":  "ㄧㄞ",
	"iao":  "ㄧㄠ",
	"iu":   "ㄧㄡ",
	"iou":  "ㄧㄡ",
	"ian":  "ㄧㄢ",
	"in":   "ㄧㄣ",
	"iang": "ㄧㄤ",
	"ing":  "ㄧㄥ",
	"iong": "ㄩㄥ",
	"u":    "ㄨ",
	"ua":   "ㄨㄚ",
	"uo":   "ㄨㄛ",
	"uai":  "ㄨㄞ",
	"ui":   "ㄨㄟ",
	"uei":  "ㄨㄟ",
	"uan":  "ㄨㄢ",
	"un":   "ㄨㄣ",
	"uen":  "ㄨㄣ",
	"uang": "ㄨㄤ",
	"ong":  "ㄨㄥ",
	"ueng": "ㄨㄥ",
	"v":    "ㄩ",
	"ve":   "ㄩㄝ",
	"van":  "ㄩㄢ",
	"vn":   "ㄩㄣ",
	"ü":    "ㄩ",
	"üe":   "ㄩㄝ",
	"üan":  "ㄩㄢ",
	"ün":   "ㄩㄣ",
}

// _zhuyinWholeSyllable holds the syllables that the initial+final split cannot
// reach: the empty-rime series, where pinyin's "i" stands for no vowel at all,
// and the zero-initial syllables, which pinyin respells with y-/w-.
var _zhuyinWholeSyllable = map[string]string{
	// Empty rime — the "i" is a placeholder, not ㄧ.
	"zhi": "ㄓ",
	"chi": "ㄔ",
	"shi": "ㄕ",
	"ri":  "ㄖ",
	"zi":  "ㄗ",
	"ci":  "ㄘ",
	"si":  "ㄙ",
	// Zero initial, i-series.
	"yi":   "ㄧ",
	"ya":   "ㄧㄚ",
	"yo":   "ㄧㄛ",
	"ye":   "ㄧㄝ",
	"yai":  "ㄧㄞ",
	"yao":  "ㄧㄠ",
	"you":  "ㄧㄡ",
	"yan":  "ㄧㄢ",
	"yin":  "ㄧㄣ",
	"yang": "ㄧㄤ",
	"ying": "ㄧㄥ",
	"yong": "ㄩㄥ",
	// Zero initial, u-series.
	"wu":   "ㄨ",
	"wa":   "ㄨㄚ",
	"wo":   "ㄨㄛ",
	"wai":  "ㄨㄞ",
	"wei":  "ㄨㄟ",
	"wan":  "ㄨㄢ",
	"wen":  "ㄨㄣ",
	"wang": "ㄨㄤ",
	"weng": "ㄨㄥ",
	// Zero initial, ü-series.
	"yu":   "ㄩ",
	"yue":  "ㄩㄝ",
	"yuan": "ㄩㄢ",
	"yun":  "ㄩㄣ",
	// Standalone finals with no initial.
	"a":   "ㄚ",
	"o":   "ㄛ",
	"e":   "ㄜ",
	"ê":   "ㄝ",
	"ai":  "ㄞ",
	"ei":  "ㄟ",
	"ao":  "ㄠ",
	"ou":  "ㄡ",
	"an":  "ㄢ",
	"en":  "ㄣ",
	"ang": "ㄤ",
	"eng": "ㄥ",
	"er":  "ㄦ",
	"hm":  "ㄏㄇ",
	"n":   "ㄋ",
	"ng":  "ㄫ",
}
