package mrt

import "testing"

func TestParseTrtcCountdown(t *testing.T) {
	cases := []struct {
		in   string
		want int32
		ok   bool
	}{
		{"04:26", 266, true},
		{"00:00", 0, true},
		{"列車進站", 0, true},
		{"資料擷取中", 0, false},
		{"", 0, false},
		{"4:70", 0, false},
	}
	for _, c := range cases {
		got, ok := parseTrtcCountdown(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("parseTrtcCountdown(%q) = %d,%v want %d,%v", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestResolveTrtcStationAmbiguity(t *testing.T) {
	names := map[string][]string{
		"忠孝復興":  {"BR10", "BL15"},
		"南港展覽館": {"BR24", "BL23"},
		"動物園":   {"BR01"},
		"台北車站":  {"BL12", "R10"},
		"頂埔":    {"BL01"},
		// 環狀線 rows: both endpoints are also TRTC stations, so only the shared
		// Y line pairs.
		"大坪林":    {"G04", "Y07"},
		"板橋":     {"BL08", "Y16"},
		"新北產業園區": {"Y20"},
	}
	cases := []struct {
		station, dest, train string
		wantS, wantD, wantL  string
		ok                   bool
	}{
		{"忠孝復興站", "南港展覽館站", "215", "BL15", "BL23", "BL", true},
		{"忠孝復興站", "南港展覽館站", "", "BR10", "BR24", "BR", true},
		{"忠孝復興站", "動物園站", "", "BR10", "BR01", "BR", true},
		{"台北車站", "頂埔站", "211", "BL12", "BL01", "BL", true},
		{"大坪林站", "新北產業園區站", "", "Y07", "Y20", "Y", true},
		{"板橋站", "大坪林站", "", "Y16", "Y07", "Y", true},
		{"板橋站", "頂埔站", "211", "BL08", "BL01", "BL", true},
		{"不存在站", "動物園站", "", "", "", "", false},
	}
	for _, c := range cases {
		s, d, l, ok := resolveTrtcStation(names, c.station, c.dest, c.train)
		if s != c.wantS || d != c.wantD || l != c.wantL || ok != c.ok {
			t.Errorf("resolve(%s→%s train=%q) = %s,%s,%s,%v want %s,%s,%s,%v",
				c.station, c.dest, c.train, s, d, l, ok, c.wantS, c.wantD, c.wantL, c.ok)
		}
	}
}

func TestTrtcBRNextKey(t *testing.T) {
	if k := trtcBRNextKey("BR16", true); k != "BR17|true" {
		t.Errorf("up from BR16 = %q", k)
	}
	if k := trtcBRNextKey("BR16", false); k != "BR15|false" {
		t.Errorf("down from BR16 = %q", k)
	}
	if k := trtcBRNextKey("BL16", true); k != "" {
		t.Errorf("non-BR id should yield empty key, got %q", k)
	}
}

func TestTrtcAliasLookup(t *testing.T) {
	names := map[string][]string{"港墘": {"BR17"}}
	if ids := trtcLookup(names, "港漧"); len(ids) != 1 || ids[0] != "BR17" {
		t.Errorf("alias lookup = %v", ids)
	}
}
