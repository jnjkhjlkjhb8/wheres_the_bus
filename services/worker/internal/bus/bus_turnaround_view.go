package bus

import "github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"

// A loop split at its turnaround is served as two directions (see the
// pipeline's splitAtTurnaround) while TDX, the stop map, history and the
// prediction model all keep it as one. These views relabel a stop's live
// output to the served directions; everything upstream keeps b.Direction.

// routeViews are the route-ETA rows for a stop. The turnaround stop ends
// direction 0 and opens direction 1, so it is listed under both.
func routeViews(b busmodel.StationMap) []busmodel.StationMap {
	t := b.TurnaroundSequence
	if t == 0 || b.StopSequence < t {
		return []busmodel.StationMap{b}
	}
	if b.StopSequence == t {
		return []busmodel.StationMap{b, returnView(b)}
	}
	return []busmodel.StationMap{returnView(b)}
}

// stationView is the station-ETA row for a stop. A rider waiting at the
// turnaround is headed back, so it counts as direction 1 there.
func stationView(b busmodel.StationMap) busmodel.StationMap {
	t := b.TurnaroundSequence
	switch {
	case t == 0:
		return b
	case b.StopSequence < t:
		b.Destination = b.TurnaroundName
		return b
	default:
		return returnView(b)
	}
}

func returnView(b busmodel.StationMap) busmodel.StationMap {
	b.Direction = 1
	return b
}
