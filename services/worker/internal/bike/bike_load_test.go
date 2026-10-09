package bike

import (
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

func TestBikeCountsDecodeAbove255(t *testing.T) {
	var avail bikeAvailability
	if err := pipeline.DecodeLiveItems(decodeInto(
		`[{"StationUID":"CHA001","ServiceStatus":1,"ServiceType":2,"AvailableReturnBikes":300,`+
			`"AvailableRentBikesDetail":{"GeneralBikes":321,"ElectricBikes":260}}]`,
	), func(item bikeAvailability) error {
		avail = item
		return nil
	}); err != nil {
		t.Fatalf("decode bike availability: %v", err)
	}
	if avail.AvailableReturnBikes != 300 ||
		avail.AvailableRentBikesDetail.GeneralBikes != 321 ||
		avail.AvailableRentBikesDetail.ElectricBikes != 260 {
		t.Fatalf("decoded counts = %+v, want 300/321/260", avail)
	}

}
