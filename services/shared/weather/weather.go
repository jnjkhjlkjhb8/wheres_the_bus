// Package weather keeps a per-city snapshot of current conditions in Redis,
// refreshed from the CWA observation and rainfall feeds. Bus ETA prediction
// reads it as model features; an empty API key disables the whole job.
package weather

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

const (
	_cwaBase    = "https://opendata.cwa.gov.tw/api/v1/rest/datastore"
	HTTPTimeout = 30 * time.Second
)

type Data struct {
	Temperature   float64 `json:"temperature"`
	Precipitation float64 `json:"precipitation"`
	WindSpeed     float64 `json:"wind_speed"`
	Humidity      float64 `json:"humidity"`
}

var _countyToCity = map[string]string{
	"臺北市": "Taipei", "新北市": "NewTaipei", "桃園市": "Taoyuan",
	"臺中市": "Taichung", "臺南市": "Tainan", "高雄市": "Kaohsiung",
	"基隆市": "Keelung", "新竹市": "Hsinchu", "新竹縣": "HsinchuCounty",
	"苗栗縣": "MiaoliCounty", "彰化縣": "ChanghuaCounty", "南投縣": "NantouCounty",
	"雲林縣": "YunlinCounty", "嘉義市": "Chiayi", "嘉義縣": "ChiayiCounty",
	"屏東縣": "PingtungCounty", "宜蘭縣": "YilanCounty", "花蓮縣": "HualienCounty",
	"臺東縣": "TaitungCounty", "澎湖縣": "PenghuCounty", "金門縣": "KinmenCounty",
	"連江縣": "LienchiangCounty",
}

func Sync(ctx context.Context, rc *redis.Client) error {
	apiKey := os.Getenv("CWA_API_KEY")
	if apiKey == "" {
		zap.S().Warnw("CWA_API_KEY not set, skipping", "component", "weather")
		return nil
	}
	if rc == nil {
		return errors.New("weather Redis client is nil")
	}
	client := &http.Client{Timeout: HTTPTimeout}
	snapshot, err := fetchWeatherSnapshot(ctx, client, _cwaBase, apiKey)
	if err != nil {
		return err
	}
	return writeWeatherSnapshot(ctx, rc, snapshot)
}

func writeWeatherSnapshot(ctx context.Context, rc *redis.Client, snapshot map[string]Data) error {
	pipe := rc.TxPipeline()
	for city, data := range snapshot {
		encoded, err := json.Marshal(data)
		if err != nil {
			return _oops.With("city", city).Wrapf(err, "marshal weather")
		}
		pipe.Set(ctx, shared.WeatherKey(city), encoded, time.Hour)
	}
	if _, err := pipe.Exec(ctx); err != nil {
		return _oops.Wrapf(err, "write weather snapshot to Redis")
	}
	zap.S().Infow("synced cities", "component", "weather", "cities", len(snapshot))
	return nil
}

func fetchWeatherSnapshot(ctx context.Context, client *http.Client, baseURL, apiKey string) (map[string]Data, error) {
	if ctx == nil {
		return nil, errors.New("weather context is nil")
	}
	if client == nil {
		return nil, errors.New("weather HTTP client is nil")
	}
	obsBody, err := fetchCWA(ctx, client, baseURL+"/O-A0003-001", apiKey)
	if err != nil {
		return nil, _oops.Wrapf(err, "fetch observations")
	}
	rainBody, err := fetchCWA(ctx, client, baseURL+"/O-A0002-001", apiKey)
	if err != nil {
		return nil, _oops.Wrapf(err, "fetch rainfall")
	}
	observations, err := parseObservations(obsBody)
	if err != nil {
		return nil, _oops.Wrapf(err, "parse observations")
	}
	rainfall, err := parseRainfall(rainBody)
	if err != nil {
		return nil, _oops.Wrapf(err, "parse rainfall")
	}
	for city, precipitation := range rainfall {
		data, ok := observations[city]
		if !ok {
			continue
		}
		data.Precipitation = precipitation
		observations[city] = data
	}
	if len(observations) == 0 {
		return nil, errors.New("weather snapshot contains no usable cities")
	}
	return observations, nil
}

func fetchCWA(ctx context.Context, client *http.Client, url, apiKey string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, _oops.Wrapf(err, "create request")
	}
	req.Header.Set("Authorization", apiKey)
	resp, err := client.Do(req)
	if err != nil {
		return nil, _oops.With("url", url).Wrapf(err, "request")
	}
	defer func() { _ = resp.Body.Close() }()
	body, readErr := io.ReadAll(resp.Body)
	if readErr != nil {
		return nil, _oops.With("url", url).Wrapf(readErr, "read body")
	}
	if resp.StatusCode != http.StatusOK {
		return nil, _oops.With("url", url).With("status_code", resp.StatusCode).Errorf("request: HTTP status")
	}
	return body, nil
}

type observationResponse struct {
	Records struct {
		Station []struct {
			GeoInfo struct {
				CountyName string `json:"CountyName"`
			} `json:"GeoInfo"`
			ObsTime struct {
				DateTime string `json:"DateTime"`
			} `json:"ObsTime"`
			WeatherElement struct {
				AirTemperature   string `json:"AirTemperature"`
				WindSpeed        string `json:"WindSpeed"`
				RelativeHumidity string `json:"RelativeHumidity"`
			} `json:"WeatherElement"`
		} `json:"Station"`
	} `json:"records"`
}

func parseObservations(body []byte) (map[string]Data, error) {
	var payload observationResponse
	if err := decodeWeatherJSON(body, &payload); err != nil {
		return nil, err
	}
	type best struct {
		time time.Time
		data Data
	}
	latest := make(map[string]best)
	for _, station := range payload.Records.Station {
		city, ok := _countyToCity[station.GeoInfo.CountyName]
		if !ok {
			continue
		}
		observedAt, err := time.Parse(time.RFC3339, station.ObsTime.DateTime)
		if err != nil {
			return nil, _oops.With("city", city).Wrapf(err, "city observation time")
		}
		if previous, exists := latest[city]; exists && !observedAt.After(previous.time) {
			continue
		}
		temperature, err := parseCWAValue(station.WeatherElement.AirTemperature, "temperature")
		if err != nil {
			return nil, _oops.With("city", city).Wrapf(err, "city")
		}
		wind, err := parseCWAValue(station.WeatherElement.WindSpeed, "wind speed")
		if err != nil {
			return nil, _oops.With("city", city).Wrapf(err, "city")
		}
		humidity, err := parseCWAValue(station.WeatherElement.RelativeHumidity, "humidity")
		if err != nil {
			return nil, _oops.With("city", city).Wrapf(err, "city")
		}
		if temperature < -90 || wind < -90 || humidity < -90 {
			continue
		}
		latest[city] = best{time: observedAt, data: Data{Temperature: temperature, WindSpeed: wind, Humidity: humidity}}
	}
	out := make(map[string]Data, len(latest))
	for city, value := range latest {
		out[city] = value.data
	}
	return out, nil
}

type rainfallResponse struct {
	Records struct {
		Station []struct {
			GeoInfo struct {
				CountyName string `json:"CountyName"`
			} `json:"GeoInfo"`
			ObsTime struct {
				DateTime string `json:"DateTime"`
			} `json:"ObsTime"`
			RainfallElement struct {
				Now struct {
					Precipitation string `json:"Precipitation"`
				} `json:"Now"`
			} `json:"RainfallElement"`
		} `json:"Station"`
	} `json:"records"`
}

func parseRainfall(body []byte) (map[string]float64, error) {
	var payload rainfallResponse
	if err := decodeWeatherJSON(body, &payload); err != nil {
		return nil, err
	}
	type best struct {
		time  time.Time
		value float64
	}
	latest := make(map[string]best)
	for _, station := range payload.Records.Station {
		city, ok := _countyToCity[station.GeoInfo.CountyName]
		if !ok {
			continue
		}
		observedAt, err := time.Parse(time.RFC3339, station.ObsTime.DateTime)
		if err != nil {
			return nil, _oops.With("city", city).Wrapf(err, "city rainfall time")
		}
		value, err := parseCWAValue(station.RainfallElement.Now.Precipitation, "precipitation")
		if err != nil {
			return nil, _oops.With("city", city).Wrapf(err, "city")
		}
		if value < 0 {
			continue
		}
		if previous, exists := latest[city]; !exists || observedAt.After(previous.time) {
			latest[city] = best{time: observedAt, value: value}
		}
	}
	out := make(map[string]float64, len(latest))
	for city, value := range latest {
		out[city] = value.value
	}
	return out, nil
}

func parseCWAValue(raw, field string) (float64, error) {
	value, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return 0, _oops.With("field", field).With("raw", raw).Wrapf(err, "parse")
	}
	return value, nil
}

func decodeWeatherJSON(body []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(body))
	if err := decoder.Decode(target); err != nil {
		return _oops.Wrapf(err, "decode JSON body")
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("JSON body contains trailing data")
		}
		return _oops.Wrapf(err, "decode JSON body trailer")
	}
	return nil
}
