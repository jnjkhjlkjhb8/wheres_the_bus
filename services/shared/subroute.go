package shared

func CanonicalSubroute(city, subRouteUID string, direction uint8) (string, uint8) {
	if city != "InterCity" || len(subRouteUID) < 2 {
		return subRouteUID, direction
	}
	suffixDir, ok := subrouteSuffixDirection(subRouteUID)
	if !ok {
		return subRouteUID, direction
	}
	if subRouteUID[len(subRouteUID)-2] == '0' {
		return subRouteUID[:len(subRouteUID)-2], suffixDir
	}
	return subRouteUID[:len(subRouteUID)-1], suffixDir
}

// subrouteSuffixDirection reads the travel direction off a UID's last character,
// reporting false when the UID does not end in a main/branch marker followed by
// a direction and so carries no suffix to strip.
func subrouteSuffixDirection(uid string) (uint8, bool) {
	marker := uid[len(uid)-2]
	if marker != '0' && (marker < 'A' || marker > 'Z') {
		return 0, false
	}
	switch uid[len(uid)-1] {
	case '1':
		return 0, true
	case '2':
		return 1, true
	}
	return 0, false
}
