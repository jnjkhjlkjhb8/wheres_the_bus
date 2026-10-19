package predict

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/dmitryikh/leaves"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/weather"
)

func TestModelPredictionAddsStopOffsetAndModelCorrection(t *testing.T) {
	model, err := leaves.LGEnsembleFromJSON(strings.NewReader(`{"name":"tree","version":"v2","num_class":1,"num_tree_per_iteration":1,"max_feature_idx":14,"tree_info":[{"tree_index":0,"num_leaves":1,"num_cat":0,"tree_structure":{"leaf_value":30}}]}`), false)
	if err != nil {
		t.Fatal(err)
	}
	p := &predictor{model: model}
	now := time.Date(2026, 7, 6, 8, 0, 0, 0, pipeline.Taipei)
	departure := time.Date(2020, 1, 1, 9, 30, 0, 0, pipeline.Taipei)
	for _, tc := range []struct {
		offset int
		want   string
	}{
		{120, "2026-07-06T09:32:30+08:00"},
		{-60, "2026-07-06T09:29:30+08:00"},
		{0, "2026-07-06T09:30:30+08:00"},
	} {
		got := p.NextBusTime(nil, StopCtx{}, Inputs{Now: now, NextDep: departure, HasOffset: true, OffsetSec: tc.offset})
		if got != tc.want {
			t.Errorf("offset %d arrival = %q, want %q", tc.offset, got, tc.want)
		}
	}
	var absent *predictor
	if got := absent.NextBusTime(nil, StopCtx{}, Inputs{NextDep: departure}); got != "" {
		t.Fatalf("absent model arrival = %q", got)
	}
}

func TestPredictionFeaturesPreserveWeatherRoutePositionAndUnknownCity(t *testing.T) {
	p := &predictor{}
	p.encoders.City = map[string]int{"Taipei": 7}
	now := time.Date(2026, 7, 6, 8, 0, 0, 0, pipeline.Taipei)
	wx := &weather.Data{Temperature: 28, Precipitation: 3, WindSpeed: 4, Humidity: 80}
	stop := StopCtx{City: "Taipei", Direction: 1, StopSequence: 3, TotalStops: 12}
	want := []float64{8, 1, 0, 28, 3, 4, 80, 1, 3, 12, 0.25, 7, -1, -1, -1}
	if got := p.features(wx, stop, now); !reflect.DeepEqual(got, want) {
		t.Fatalf("features = %v, want %v", got, want)
	}
	weekend := time.Date(2026, 7, 4, 12, 0, 0, 0, pipeline.Taipei)
	want = []float64{12, 6, 1, 0, 0, 0, 0, 0, 0, 0, 0, -1, -1, -1, -1}
	if got := p.features(nil, StopCtx{City: "unknown"}, weekend); !reflect.DeepEqual(got, want) {
		t.Fatalf("default features = %v, want %v", got, want)
	}
}

func TestPredictorLoadHandlesMissingInvalidAndAvailableEncoders(t *testing.T) {
	model, err := os.ReadFile("testdata/constant_eta.xgboost")
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, encoders string
		present        bool
	}{
		{"missing", "", false},
		{"invalid", "{", true},
		{"valid", `{"city":{"Taipei":7},"plate_numb":{"ABC":9}}`, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "eta.json")
			if err := os.WriteFile(path, model, 0o600); err != nil {
				t.Fatal(err)
			}
			if tc.present {
				if err := os.WriteFile(filepath.Join(filepath.Dir(path), "eta_encoders.json"), []byte(tc.encoders), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("BUS_ETA_MODEL_PATH", path)
			p := newPredictor()
			if p.model == nil {
				t.Fatal("model did not load")
			}
			if tc.name == "valid" && (p.encoders.City["Taipei"] != 7 || p.encoders.PlateNumb["ABC"] != 9) {
				t.Fatalf("encoders = %+v", p.encoders)
			}
		})
	}
	t.Setenv("BUS_ETA_MODEL_PATH", filepath.Join(t.TempDir(), "missing.json"))
	if got := newPredictor(); got.model != nil {
		t.Fatal("missing model was loaded")
	}
}
