package pipeline

import "time"

// Taipei is the one timezone the whole schedule domain is expressed in.
var Taipei = mustLoadTaipei()

func mustLoadTaipei() *time.Location {
	loc, err := time.LoadLocation("Asia/Taipei")
	if err != nil {
		panic("cannot load Asia/Taipei: " + err.Error())
	}
	return loc
}
