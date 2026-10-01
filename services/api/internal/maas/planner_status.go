package maas

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
)

const (
	// PlannerStatusPath is what the app polls.
	PlannerStatusPath    = "/api/planner"
	_plannerStatusMaxAge = 20
)

// Capability names. These are the contract with the app: it maps each to a
// control in the options sheet, and renders nothing for a name it does not
// recognise, so adding one here cannot break an older build.
const (
	// Shared by both planners.
	_capTransitModes    = "transitModes"
	_capItineraryCount  = "itineraryCount"
	_capTransferWindow  = "transferWindow"
	_capFirstLastMile   = "firstLastMile"
	_capPricePreference = "pricePreference"

	// MOTIS only.
	_capWheelchair        = "wheelchair"
	_capWalkingSpeed      = "walkingSpeed"
	_capExtraTransferTime = "extraTransferTime"
	_capMaxTransfers      = "maxTransfers"
	_capMaxTravelTime     = "maxTravelTime"
	_capAvoidReservation  = "avoidReservation"
	_capCarryBike         = "carryBike"
	_capEarlierLater      = "earlierLater"
	_capLegAlternatives   = "legAlternatives"
	_capViaStop           = "viaStop"
	_capDirectComparison  = "directComparison"
	_capAvoidElevation    = "avoidElevation"
	_capShowSkippedStops  = "showSkippedStops"
	_capIgnoreRealtime    = "ignoreRealtime"
)

func plannerCapabilities(backend PlannerBackend) []string {
	shared := []string{
		_capTransitModes,
		_capItineraryCount,
		_capTransferWindow,
		_capFirstLastMile,
		_capPricePreference,
	}
	if backend != _plannerMotis {
		return shared
	}
	// Grown once to its final length rather than five times by append.
	capabilities := make([]string, 0, len(shared)+14)
	capabilities = append(capabilities, shared...)
	return append(capabilities,
		_capWheelchair,
		_capWalkingSpeed,
		_capExtraTransferTime,
		_capMaxTransfers,
		_capMaxTravelTime,
		_capAvoidReservation,
		_capCarryBike,
		_capEarlierLater,
		_capLegAlternatives,
		_capViaStop,
		_capDirectComparison,
		_capAvoidElevation,
		_capShowSkippedStops,
		_capIgnoreRealtime,
	)
}

// plannerStatusBody is the response. The status fields are for an operator; the
// app reads `backend` and `capabilities` and ignores the rest.
type plannerStatusBody struct {
	PlannerStatus
	Capabilities []string `json:"capabilities"`
}

// RegisterPlannerStatusRoutes mounts the endpoint. Unlike the geocode proxy this
// is always mounted: an app that cannot tell which planner is live has to guess,
// and guessing is what this exists to remove.
func RegisterPlannerStatusRoutes(r gin.IRoutes, monitor *PlannerHealthMonitor, limit gin.HandlerFunc) {
	r.GET(PlannerStatusPath, limit, handlePlannerStatus(monitor))
}

func handlePlannerStatus(monitor *PlannerHealthMonitor) gin.HandlerFunc {
	return func(c *gin.Context) {
		status := monitor.Status()
		c.Header("Cache-Control", "public, max-age="+strconv.Itoa(_plannerStatusMaxAge))
		c.JSON(http.StatusOK, plannerStatusBody{
			PlannerStatus: status,
			Capabilities:  plannerCapabilities(status.Backend),
		})
	}
}
