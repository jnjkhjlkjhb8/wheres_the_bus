package busmodel

import (
	"encoding/json"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
)

// RawRoute decodes a TDX Bus/Route element: a route and its per-direction
// subroutes, operators, and first/last service times.
type RawRoute struct {
	RouteUID  string `json:"RouteUID"`
	RouteName struct {
		Zhtw string `json:"Zh_tw"`
	} `json:"RouteName"`
	DepartureStopNameZh   string `json:"DepartureStopNameZh"`
	DestinationStopNameZh string `json:"DestinationStopNameZh"`
	Operators             []struct {
		OperatorID string `json:"OperatorID"`
	} `json:"Operators"`
	SubRoutes []struct {
		SubRouteUID  string `json:"SubRouteUID"`
		SubRouteID   string `json:"SubRouteID"`
		SubRouteName struct {
			Zhtw string `json:"Zh_tw"`
		} `json:"SubRouteName"`
		Direction             uint8  `json:"Direction"`
		DepartureStopNameZh   string `json:"DepartureStopNameZh,omitempty"`
		DestinationStopNameZh string `json:"DestinationStopNameZh,omitempty"`
		FirstBusTime          string `json:"FirstBusTime"`
		LastBusTime           string `json:"LastBusTime"`
		HolidayFirstBusTime   string `json:"HolidayFirstBusTime"`
		HolidayLastBusTime    string `json:"HolidayLastBusTime"`
	} `json:"SubRoutes"`
}

// RawFare decodes a TDX Bus/RouteFare element. Fare detail arrays are kept as
// raw JSON and stored verbatim. IsForAllSubRoutes marks a route-wide fare that
// applies when no subroute-specific fare exists.
type RawFare struct {
	RouteID           string          `json:"RouteID"`
	SubRouteID        string          `json:"SubRouteID"`
	FarePricingType   int32           `json:"FarePricingType"`
	IsFreeBus         uint8           `json:"IsFreeBus"`
	IsForAllSubRoutes uint8           `json:"IsForAllSubRoutes"`
	SectionFares      json.RawMessage `json:"SectionFares"`
	StageFares        json.RawMessage `json:"StageFares"`
	ODFares           json.RawMessage `json:"ODFares"`
}

// RawStopOfRoute decodes a TDX Bus/StopOfRoute element: the ordered stops of one
// subroute direction.
type RawStopOfRoute struct {
	RouteUID    string `json:"RouteUID"`
	SubRouteUID string `json:"SubRouteUID"`
	Direction   uint8  `json:"Direction"`
	Stops       []struct {
		StopUID  string `json:"StopUID"`
		StopName struct {
			Zhtw string `json:"Zh_tw"`
		} `json:"StopName"`
		StopSequence uint8 `json:"StopSequence"`
		StopPosition struct {
			PositionLon float64 `json:"PositionLon"`
			PositionLat float64 `json:"PositionLat"`
		} `json:"StopPosition"`
		StationID        string `json:"StationID"`
		LocationCityCode string `json:"LocationCityCode"`
	} `json:"Stops"`
}

// RawDailyTimetable decodes a TDX Bus/DailyTimeTable element: per-trip
// stop-by-stop scheduled times for one service day, cached for realtime use.
type RawDailyTimetable struct {
	SubRouteUID string `json:"SubRouteUID"`
	Direction   *uint8 `json:"Direction"`
	Timetables  []struct {
		TripID     string `json:"TripID"`
		IsLowFloor bool   `json:"IsLowFloor"`
		StopTimes  []struct {
			StopSequence  int64  `json:"StopSequence"`
			StopUID       string `json:"StopUID"`
			ArrivalTime   string `json:"ArrivalTime"`
			DepartureTime string `json:"DepartureTime"`
		} `json:"StopTimes"`
	} `json:"Timetables"`
}

// RawSchedule decodes a TDX Bus/Schedule element: recurring service. A
// subroute uses either fixed Timetables (per-stop times) or Frequencys
// (headway windows), keyed by a weekly ServiceDay pattern.
type RawSchedule struct {
	SubRouteUID string `json:"SubRouteUID"`
	RouteUID    string `json:"RouteUID"`
	Direction   uint8  `json:"Direction"`
	Timetables  []struct {
		TripID     string `json:"TripID"`
		IsLowFloor bool   `json:"IsLowFloor"`
		ServiceDay struct {
			Sunday    uint8 `json:"Sunday"`
			Monday    uint8 `json:"Monday"`
			Tuesday   uint8 `json:"Tuesday"`
			Wednesday uint8 `json:"Wednesday"`
			Thursday  uint8 `json:"Thursday"`
			Friday    uint8 `json:"Friday"`
			Saturday  uint8 `json:"Saturday"`
		} `json:"ServiceDay"`
		StopTimes []struct {
			StopSequence int    `json:"StopSequence"`
			StopUID      string `json:"StopUID"`
			StopName     struct {
				Zhtw string `json:"Zh_tw"`
			} `json:"StopName"`
			ArrivalTime   string `json:"ArrivalTime"`
			DepartureTime string `json:"DepartureTime"`
		} `json:"StopTimes"`
	} `json:"Timetables"`
	Frequencys []struct {
		StartTime      string `json:"StartTime"`
		EndTime        string `json:"EndTime"`
		MinHeadwayMins uint8  `json:"MinHeadwayMins"`
		MaxHeadwayMins uint8  `json:"MaxHeadwayMins"`
		ServiceDay     struct {
			Sunday    uint8 `json:"Sunday"`
			Monday    uint8 `json:"Monday"`
			Tuesday   uint8 `json:"Tuesday"`
			Wednesday uint8 `json:"Wednesday"`
			Thursday  uint8 `json:"Thursday"`
			Friday    uint8 `json:"Friday"`
			Saturday  uint8 `json:"Saturday"`
		} `json:"ServiceDay"`
	} `json:"Frequencys"`
}

type RawEstimated struct {
	PlateNumb string `json:"PlateNumb"`
	StopUID   string `json:"StopUID"`
	// Taipei and NewTaipei publish route-level arrivals: their entries carry only
	// RouteUID, with SubRouteUID absent. buildBusEtaMap fans those out across the
	// route's subroutes, so both fields must be decoded.
	SubRouteUID string `json:"SubRouteUID"`
	RouteUID    string `json:"RouteUID"`
	Direction   uint8  `json:"Direction"`
	// TDX spells this "EstimateTime", not "EstimatedTime". The struct field keeps
	// the grammatical name; only the tag has to match the wire.
	EstimatedTime int32  `json:"EstimateTime"`
	NextBusTime   string `json:"NextBusTime"`
	StopStatus    uint8  `json:"StopStatus"`
	SrcUpdateTime string `json:"SrcUpdateTime"`
	IsLastBus     uint8  `json:"IsLastBus"`
	DataTime      string `json:"DataTime"`
	SrcTransTime  string `json:"SrcTransTime"`
}

// RawPosition decodes a TDX Bus/RealTimeByFrequency element: a bus's live GPS
// position and status, used to attach the nearest vehicle to a stop's ETA.
type RawPosition struct {
	PlateNumb   string `json:"PlateNumb"`
	SubRouteUID string `json:"SubRouteUID"`
	StopUID     string `json:"StopUID"`
	Direction   uint8  `json:"Direction"`
	BusPosition struct {
		PositionLon float64 `json:"PositionLon"`
		PositionLat float64 `json:"PositionLat"`
	} `json:"BusPosition"`
	Azimuth    float64 `json:"Azimuth"`
	Speed      float64 `json:"Speed"`
	DutyStatus uint8   `json:"DutyStatus"`
	BusStatus  uint8   `json:"BusStatus"`
	GPSTime    string  `json:"GPSTime"`
	// CrowdLevel is not a TDX field: no bus feed TDX serves carries crowding.
	// It rides here because Data.taipei publishes it per vehicle and this is the
	// per-vehicle record the ETA job already threads through (datataipei.go).
	CrowdLevel models.BusCrowdLevel `json:"CrowdLevel,omitempty"`
}

// StationMap is one stop of one subroute joined to its station group and
// coordinates, as loaded by busstaticmp and consumed by the bus ETA builder.
type StationMap struct {
	StationUID    string
	StationName   string
	GroupUID      string
	GroupName     string
	SubRouteUID   string
	RouteUID      string
	SubRouteName  string
	Destination   string
	Direction     uint8
	StopUID       string
	StopSequence  uint8
	Lat           float64
	Lon           float64
	AliasStopUIDs []string
}

// RawShape decodes a TDX Bus/Shape element: the WKT geometry of a route or
// subroute. When SubRouteUID is empty the geometry applies to every subroute of
// the route.
type RawShape struct {
	SubRouteUID string `json:"SubRouteUID,omitempty"`
	RouteUID    string `json:"RouteUID"`
	Direction   uint8  `json:"Direction"`
	Geometry    string `json:"Geometry"`
	UpdateTime  string `json:"UpdateTime"`
}

// RawOperator decodes a TDX Bus/Operator element for the atomic city
// snapshot's target upsert and route enrichment.
type RawOperator struct {
	OperatorID   string `json:"OperatorID"`
	OperatorName struct {
		Zhtw string `json:"Zh_tw"`
	} `json:"OperatorName"`
	OperatorPhone string `json:"OperatorPhone"`
	OperatorURL   string `json:"OperatorUrl"`
	AuthorityCode string `json:"AuthorityCode"`
}

// OperatorJSON is the compact operator shape embedded as jsonb in a
// subroute's operators column (lowercase keys, distinct from the TDX field names).
type OperatorJSON struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Phone string `json:"phone"`
	URL   string `json:"url"`
}

// Cities is the set of TDX city codes iterated by every bus/bike ingestion loop.
// "InterCity" is the highway coach operator, not a municipality. Order is not
// significant.
var Cities = []string{
	"Taipei", "NewTaipei", "Taoyuan", "Taichung", "Tainan", "Kaohsiung",
	"InterCity", "Hsinchu", "HsinchuCounty", "MiaoliCounty", "ChanghuaCounty",
	"NantouCounty", "YunlinCounty", "ChiayiCounty", "Chiayi", "PingtungCounty",
	"YilanCounty", "HualienCounty", "TaitungCounty", "PenghuCounty", "KinmenCounty", "LienchiangCounty", "Keelung",
}

var CityPrefix = func() map[string]string {
	out := make(map[string]string, len(Cities))
	for _, city := range Cities {
		out[city] = shared.UIDPrefixForCity(city)
	}
	return out
}()

// CityToCode is the inverse of citymap, resolving a short prefix back to a TDX
// city code. Used when rail data carries LocationCityCode prefixes.
var CityToCode = func() map[string]string {
	out := make(map[string]string, len(CityPrefix))
	for city, prefix := range CityPrefix {
		out[prefix] = city
	}
	return out
}()
