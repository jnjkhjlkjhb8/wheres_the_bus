package transit

import (
	"errors"
	"testing"

	pgxmock "github.com/pashagolub/pgxmock/v4"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestBusStationGroupCarriesRoutesAndFailsWhole(t *testing.T) {
	queryErr := errors.New("query failed")
	tests := []struct {
		name       string
		membersErr error
		routesErr  error
		wantCode   codes.Code
	}{
		{name: "routes attached"},
		{name: "members fail", membersErr: queryErr, wantCode: codes.Internal},
		{name: "routes fail", routesErr: queryErr, wantCode: codes.Internal},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			db, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			db.ExpectQuery("SELECT group_name, city").WithArgs("G").
				WillReturnRows(pgxmock.NewRows([]string{"group_name", "city", "st_x", "st_y"}).AddRow("站", "Taipei", 121.5, 25.0))
			members := db.ExpectQuery("FROM bus_station_group_members\\s+WHERE").WithArgs("G")
			if tt.membersErr != nil {
				members.WillReturnError(tt.membersErr)
			} else {
				members.WillReturnRows(pgxmock.NewRows([]string{"station_uid", "station_id", "station_name", "st_x", "st_y"}).AddRow("U", "1", "站", 121.5, 25.0))
				routes := db.ExpectQuery("DISTINCT ON").WithArgs("G")
				if tt.routesErr != nil {
					routes.WillReturnError(tt.routesErr)
				} else {
					routes.WillReturnRows(pgxmock.NewRows([]string{"station_uid", "sub_route_uid", "route_name", "direction", "destin"}).AddRow("U", "TPE307", "307", int32(0), "板橋"))
				}
			}

			got, err := busStationGroup(t.Context(), db, "G")

			if status.Code(err) != tt.wantCode {
				t.Fatalf("code = %v, want %v (err %v)", status.Code(err), tt.wantCode, err)
			}
			if tt.wantCode == codes.OK && (len(got.Routes) != 1 || got.Routes[0].SubRouteUid != "TPE307") {
				t.Fatalf("routes = %v, want the one TPE307 row", got.Routes)
			}
		})
	}
}
