package bus

import "testing"

func TestBusDisplayStopRows(t *testing.T) {
	routes := []rawBusDisplayStopOfRoute{
		{
			RouteUID:  "TPE10132",
			Direction: 0,
			Stops: []struct {
				StopUID  string `json:"StopUID"`
				StopName struct {
					Zhtw string `json:"Zh_tw"`
				} `json:"StopName"`
				StopSequence uint8  `json:"StopSequence"`
				StationID    string `json:"StationID"`
			}{
				{StopUID: "TPE33210", StopSequence: 1, StationID: "2717"},
				{StopUID: "TPE33211", StopSequence: 2, StationID: "6005"},
				// Unusable: no station to join on.
				{StopUID: "TPE33212", StopSequence: 3},
				// Unusable: no sequence to order by.
				{StopUID: "TPE33213", StationID: "6006"},
			},
		},
	}
	routes[0].Stops[0].StopName.Zhtw = "歡仔園"
	routes[0].Stops[1].StopName.Zhtw = "僑中一街"
	routes[0].Stops[2].StopName.Zhtw = "無站位"
	routes[0].Stops[3].StopName.Zhtw = "無站序"

	rows := busDisplayStopRows(routes)
	if len(rows) != 2 {
		t.Fatalf("rows = %#v, want the two joinable, orderable stops", rows)
	}
	want := []any{"TPE10132", int16(0), "TPE33210", int16(1), "2717", "歡仔園"}
	for i, got := range rows[0] {
		if got != want[i] {
			t.Fatalf("row = %#v, want %#v", rows[0], want)
		}
	}
}
