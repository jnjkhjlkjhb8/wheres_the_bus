package dataset

import (
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/busmodel"
)

type LandFamily int

const (
	FamilyNone LandFamily = iota
	FamilyBusCity
	FamilyBikeCity
	FamilyMetroSystem
	FamilyRailSingle
	FamilyRailDate
)

type Spec struct {
	RawTable   string
	PartCol    string
	Partitions func() []string
	LoadParts  func() []string
	Family     LandFamily
	APISeg     string
	Name       func(part string) string
	LoadKey    string
	FoldedInto string
	LandOnly   bool
	ExportOnly bool
	StaleOK    bool
}

// fetched reports whether the ingestor issues requests for this dataset.
func (d Spec) Fetched() bool {
	return d.Family != FamilyNone && !d.LandOnly
}

// loadPartitions returns the Partitions the loader processes, defaulting to the
// landed set when the dataset loads everything it lands.
func (d Spec) LoadPartitions() []string {
	if d.LoadParts != nil {
		return d.LoadParts()
	}
	return d.Partitions()
}

// url builds the landing URL for one partition of a fetched dataset.
func (d Spec) URL(part string) string {
	switch d.Family {
	case FamilyBusCity:
		if part == "InterCity" {
			return "/v2/Bus/" + d.APISeg + "/InterCity"
		}
		return "/v2/Bus/" + d.APISeg + "/City/" + part
	case FamilyBikeCity:
		return "/v2/Bike/" + d.APISeg + "/City/" + part
	case FamilyMetroSystem:
		return "/v2/Rail/Metro/" + d.APISeg + "/" + part
	case FamilyRailSingle:
		return "/v2/Rail/" + d.APISeg
	case FamilyRailDate:
		return "/v2/Rail/" + d.APISeg + "/TrainDate/" + part
	case FamilyNone:
		// Zero value: no registry entry, so no URL.
	}
	return ""
}

// Partition enumerators shared by landing and loading so the two stages read the
// same set. AllCities/BikeCities/DailyTimetableCities/singlePartition were
// loader-local closures before the registry unified them.
func AllCities() []string { return busmodel.Cities }

func BusLoadCities() []string {
	out := make([]string, 0, len(busmodel.Cities)-1)
	for _, city := range busmodel.Cities {
		if city == "LienchiangCounty" || city == "InterCity" {
			continue
		}
		out = append(out, city)
	}
	return append(out, "InterCity")
}

var _displayStopCities = []string{"Taipei", "NewTaipei", "Taoyuan", "Taichung", "Tainan"}

func DisplayStopCities() []string { return _displayStopCities }

func BikeCities() []string {
	var out []string
	for _, c := range busmodel.Cities {
		if !BikeSkip[c] {
			out = append(out, c)
		}
	}
	return out
}

// DailyTimetableLoadCities is the landing set plus the cities whose partition is
// landed from somewhere other than TDX — Taipei, from Data.taipei.
func DailyTimetableLoadCities() []string {
	return append(DailyTimetableCities(), DataTaipeiCity)
}

func DailyTimetableCities() []string {
	var out []string
	for _, c := range busmodel.Cities {
		if !BusDailyTimetableSkip(c) {
			out = append(out, c)
		}
	}
	return out
}

func singlePartition() []string { return []string{""} }

// busName builds a bus dataset's per-partition IMS cache identity ("bus_"+API+
// city), matching the legacy ingestor names byte for byte.
func busName(apiSeg string) func(string) string {
	return func(p string) string { return "bus_" + apiSeg + p }
}

// busDataset builds one per-city bus static dataset. Only bus_route carries the
// "bus" LoadKey; every other correlated table is folded into that one atomic
// city snapshot and has no standalone target transaction.
func busDataset(apiSeg, rawTable, loadKey, foldedInto string) Spec {
	spec := Spec{
		RawTable: rawTable, PartCol: "city", Partitions: AllCities,
		Family: FamilyBusCity, APISeg: apiSeg, Name: busName(apiSeg),
		LoadKey: loadKey, FoldedInto: foldedInto,
	}
	if loadKey == "bus" {
		spec.LoadParts = BusLoadCities
	}
	return spec
}

// railSingle builds an unpartitioned TRA/THSR dataset (single TRUNCATE-lifecycle
// partition). name is constant because the endpoint carries no partition value.
func railSingle(apiSeg, rawTable, loadKey, imsName string) Spec {
	return Spec{
		RawTable: rawTable, PartCol: "", Partitions: singlePartition,
		Family: FamilyRailSingle, APISeg: apiSeg,
		Name:    func(string) string { return imsName },
		LoadKey: loadKey,
	}
}

func railSingleExport(apiSeg, rawTable, imsName string) Spec {
	spec := railSingle(apiSeg, rawTable, "", imsName)
	spec.ExportOnly = true
	return spec
}

func metroExport(apiSeg, rawTable, imsPrefix string, systems func() []string) Spec {
	return Spec{
		RawTable: rawTable, PartCol: "system",
		Partitions: systems,
		Family:     FamilyMetroSystem, APISeg: apiSeg,
		Name:       func(part string) string { return imsPrefix + part },
		ExportOnly: true,
	}
}

func Registry() []Spec {
	return []Spec{
		busDataset("Operator", "bus_operator", "", "bus"),
		busDataset("Route", "bus_route", "bus", ""),
		busDataset("StopOfRoute", "bus_stopofroute", "", "bus"),
		busDataset("Shape", "bus_shape", "", "bus"),
		busDataset("Schedule", "bus_schedule", "", "bus"),
		busDataset("Station", "bus_station", "", "bus"),
		busDataset("StationGroup", "bus_stationgroup", "", "bus"),
		busDataset("RouteFare", "bus_routefare", "", "bus"),
		{RawTable: "bus_displaystopofroute", PartCol: "city", Partitions: DisplayStopCities,
			Family: FamilyBusCity, APISeg: "DisplayStopOfRoute",
			Name: busName("DisplayStopOfRoute"), LoadKey: "bus_displaystop"},
		// Landed and loaded for the same city set: TDX answers HTTP 400 (not an
		// empty payload) for the cities in BusDailyTimetableSkip, so landing them
		// only produced a nightly ingest failure for data no loader would read.
		{RawTable: "bus_dailytimetable", PartCol: "city", Partitions: DailyTimetableCities,
			LoadParts: DailyTimetableLoadCities, Family: FamilyBusCity, APISeg: "DailyTimeTable",
			Name: busName("DailyTimeTable"), LoadKey: "bus_dailytimetable"},
		// Bus/Stop is intentionally absent from the fetch and reverse maps: it is
		// never fetched and never loaded. The whitelist/DDL entry is kept because
		// the table may already exist on Azure.
		{RawTable: "bus_stop", LandOnly: true},
		{RawTable: "bike_station", PartCol: "city", Partitions: BikeCities,
			Family: FamilyBikeCity, APISeg: "Station",
			Name: func(p string) string { return "bike_" + p }, LoadKey: "bike"},
		{RawTable: "metro_station", PartCol: "system", Partitions: func() []string { return MetroStationSystems },
			Family: FamilyMetroSystem, APISeg: "Station",
			Name: func(p string) string { return "metro_station_" + p }, LoadKey: "mrt_station"},
		{RawTable: "metro_schedule", PartCol: "system", Partitions: func() []string { return MetroFirstLast },
			Family: FamilyMetroSystem, APISeg: "FirstLastTimetable",
			Name: func(p string) string { return "metro_fl_" + p }, LoadKey: "mrt_firstlast", StaleOK: true},
		{RawTable: "metro_odfare", PartCol: "system", Partitions: func() []string { return MetroODFare },
			Family: FamilyMetroSystem, APISeg: "ODFare",
			Name: func(p string) string { return "metro_od_" + p }, LoadKey: "mrt_odfare"},
		{RawTable: "metro_s2straveltime", PartCol: "system", Partitions: func() []string { return MetroS2STravelTime },
			Family: FamilyMetroSystem, APISeg: "S2STravelTime",
			Name: func(p string) string { return "metro_s2s_" + p }, LoadKey: "mrt_traveltime"},
		{RawTable: "metro_linetransfer", PartCol: "system", Partitions: func() []string { return MetroLineTransfer },
			Family: FamilyMetroSystem, APISeg: "LineTransfer",
			Name: func(p string) string { return "metro_transfer_" + p }, FoldedInto: "mrt_traveltime"},
		railSingle("TRA/Station", "tra_station", "tra_station", "tra_station"),
		railSingle("THSR/Station", "thsr_station", "thsr_station", "thsr_station"),
		railSingle("TRA/ODFare", "tra_odfare", "tra_fare", "tra_odfare"),
		railSingle("THSR/ODFare", "thsr_odfare", "thsr_fare", "thsr_odfare"),
		railSingle("TRA/Shape", "tra_shape", "tra_shape", "tra_shape"),
		railSingle("THSR/Shape", "thsr_shape", "thsr_shape", "thsr_shape"),
		{RawTable: "metro_shape", PartCol: "system", Partitions: func() []string { return MetroStationSystems },
			Family: FamilyMetroSystem, APISeg: "Shape",
			Name: func(p string) string { return "metro_shape_" + p }, LoadKey: "metro_shape"},
		{RawTable: "tra_dailytimetable", PartCol: "traindate", Partitions: func() []string { return RailDateWindow(60) },
			Family: FamilyRailDate, APISeg: "TRA/DailyTimetable",
			Name: func(p string) string { return "tra_daily_" + p }, LoadKey: "tra_timetable"},
		{RawTable: "thsr_dailytimetable", PartCol: "traindate", Partitions: func() []string { return RailDateWindow(45) },
			Family: FamilyRailDate, APISeg: "THSR/DailyTimetable",
			Name: func(p string) string { return "thsr_daily_" + p }, LoadKey: "thsr_timetable"},
		// TRA/TrainType resolves on the reverse path (its DDL/whitelist entry is
		// kept) but is never fetched: nothing loads raw_tdx.tra_traintype, and
		// train-type data arrives inside the daily-timetable payloads.
		{RawTable: "tra_traintype", Family: FamilyRailSingle, APISeg: "TRA/TrainType", LandOnly: true},

		metroExport("Route", "metro_route", "metro_route_", func() []string { return MetroSystemsAll }),
		metroExport("StationOfRoute", "metro_stationofroute", "metro_sor_", func() []string { return MetroSystemsAll }),
		metroExport("Line", "metro_line", "metro_line_", func() []string { return MetroSystemsAll }),
		metroExport("Frequency", "metro_frequency", "metro_freq_", func() []string { return MetroFrequency }),
		metroExport("StationExit", "metro_stationexit", "metro_exit_", func() []string { return MetroExit }),
		railSingleExport("THSR/StationExit", "thsr_stationexit", "thsr_stationexit"),
		railSingleExport("Operator", "rail_operator", "rail_operator"),
	}
}

// FamSeg keys the reverse index: (family, endpoint segment) → dataset. The
// segment is family-scoped so bus "Station" and metro "Station" do not collide.
type FamSeg struct {
	Family LandFamily
	Seg    string
}

var RawTargetIndex = buildRawTargetIndex()

func buildRawTargetIndex() map[FamSeg]Spec {
	m := make(map[FamSeg]Spec)
	for _, d := range Registry() {
		if d.Family == FamilyNone {
			continue
		}
		m[FamSeg{d.Family, d.APISeg}] = d
	}
	return m
}

// cities with no public bike-share feed.
var BikeSkip = map[string]bool{
	"Keelung": true, "HsinchuCounty": true, "NantouCounty": true,
	"YilanCounty": true, "PenghuCounty": true, "KinmenCounty": true,
	"LienchiangCounty": true, "InterCity": true, "HualienCounty": true,
}

// BusDailyTimetableSkip lists cities whose daily-timetable feed TDX does not
// serve, so the TDX landing Partitions skip them.
func BusDailyTimetableSkip(city string) bool {
	return city == "Taipei" || city == "NewTaipei" || city == "Tainan" ||
		city == "KinmenCounty" || city == "LienchiangCounty"
}

// RailDateWindow returns today..today+n as YYYY-MM-DD strings, matching the
// ingestor's landing window (day 0 = today) so every landed timetable partition
// has a loader partition.
func RailDateWindow(n int) []string {
	today := time.Now()
	out := make([]string, 0, n+1)
	for i := 0; i <= n; i++ {
		out = append(out, today.AddDate(0, 0, i).Format(time.DateOnly))
	}
	return out
}

const DataTaipeiCity = "Taipei"

var (
	// MetroSystemsAll is every rail system TDX serves. Station, Shape, ODFare,
	// Route, StationOfRoute and Line all accept the full set.
	MetroSystemsAll = []string{
		"TRTC", "KRTC", "TYMC", "KLRT", "NTDLRT", "NTALRT", "TMRT", "NTMC", "TRTCMG",
	}

	MetroStationSystems = MetroSystemsAll
	MetroODFare         = MetroSystemsAll
	// FirstLastTimetable omits the two newest light-rail lines.
	MetroFirstLast     = []string{"TRTC", "KRTC", "TYMC", "KLRT", "TMRT", "NTMC", "TRTCMG"}
	MetroS2STravelTime = []string{"TRTC", "KRTC", "TYMC", "KLRT", "TMRT", "NTMC"}
	MetroLineTransfer  = []string{"TRTC", "KRTC", "NTMC"}
	MetroFrequency     = []string{"TRTC", "KRTC", "TYMC", "TMRT", "NTMC"}
	MetroExit          = []string{"TRTC", "KRTC", "TYMC", "TMRT", "NTMC", "TRTCMG"}
)
