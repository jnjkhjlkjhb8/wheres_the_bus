package bus

import (
	"sort"
	"strconv"
	"strings"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

type convergenceViolation struct {
	canonical string
	issue     string
	detail    string
}

func findConvergenceViolations(subRoutemap map[string]*models.BusSubroute, nameObs map[string]map[string]struct{}) []convergenceViolation {
	var out []convergenceViolation
	for uid, sub := range subRoutemap {
		if n := len(sub.Directions); n > 2 {
			out = append(out, convergenceViolation{uid, "too_many_directions", strconv.Itoa(n)})
		}
	}
	out = append(out, findBusNameViolations(nameObs)...)
	sortBusConvergenceViolations(out)
	return out
}

func findBusNameViolations(nameObs map[string]map[string]struct{}) []convergenceViolation {
	var out []convergenceViolation
	for uid, names := range nameObs {
		if len(names) > 1 {
			distinct := pipeline.SortedKeys(names)
			out = append(out, convergenceViolation{uid, "name_mismatch", strings.Join(distinct, "|")})
		}
	}
	return out
}

func sortBusConvergenceViolations(out []convergenceViolation) {
	sort.Slice(out, func(i, j int) bool {
		if out[i].canonical != out[j].canonical {
			return out[i].canonical < out[j].canonical
		}
		return out[i].issue < out[j].issue
	})
}
