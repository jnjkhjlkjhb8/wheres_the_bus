package pipeline

import (
	"errors"
	"fmt"
	"strings"

	"github.com/samber/oops"
)

func errMentions(err error, want string) bool {
	if err == nil {
		return false
	}
	haystack := []string{err.Error()}
	var structured oops.OopsError
	if errors.As(err, &structured) {
		for key, value := range structured.Context() {
			haystack = append(haystack, key, fmt.Sprint(value))
		}
	}
	for _, token := range strings.Fields(want) {
		found := false
		for _, candidate := range haystack {
			if strings.Contains(candidate, token) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}
