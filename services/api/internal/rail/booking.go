package rail

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/go-resty/resty/v2"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"go.uber.org/zap"
)

type BookingProxy struct {
	tra  *resty.Client
	thsr *resty.Client
}

func NewBookingProxy(tdx *shared.TDXClient) *BookingProxy {
	return &BookingProxy{
		tra:  tdx.NewAuthedClient("https://tdx.transportdata.tw/api/maas-tra"),
		thsr: tdx.NewAuthedClient("https://tdx.transportdata.tw/api/maas-thsr"),
	}
}

// tdxBookingResponse is the TDX deeplink exchange envelope. On success `data`
// holds the redirect URL; on failure `data` is absent and `error` is set.
type tdxBookingResponse struct {
	Result string `json:"result"`
	Data   struct {
		Deeplink string `json:"deeplink"`
		Expired  string `json:"expired"`
	} `json:"data"`
}

// _bookingDetailLimit caps how much of an upstream error body reaches the log.
// TDX failure envelopes are short; a cap keeps a surprise HTML error page from
// flooding the line.
const _bookingDetailLimit = 240

func bookingDetail(res *resty.Response, body tdxBookingResponse) string {
	raw := strings.TrimSpace(string(res.Body()))
	raw = strings.Join(strings.Fields(raw), " ")
	if len(raw) > _bookingDetailLimit {
		raw = raw[:_bookingDetailLimit] + "…"
	}
	return fmt.Sprintf("status=%d result=%q body=%q", res.StatusCode(), body.Result, raw)
}

var (
	_trainDatePattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	_trainTimePattern = regexp.MustCompile(`^\d{2}:\d{2}$`)
)

// _maxTicketsPerCategory is TDX's documented per-category ceiling.
const _maxTicketsPerCategory = 10

func queryIntInRange(c *gin.Context, name string, fallback, lo, hi int) (int, error) {
	raw := strings.TrimSpace(c.Query(name))
	if raw == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || !ticketCountInRange(n, lo, hi) {
		return 0, _oops.With("name", name).With("min", lo).With("max", hi).Errorf("must be an integer")
	}
	return n, nil
}

func ticketCountInRange(value, lo, hi int) bool {
	return value >= lo && value <= hi
}

func parseTicketCounts(c *gin.Context) (map[string]int, error) {
	counts, total, err := collectTicketCounts(c)
	if err != nil {
		return nil, err
	}
	// No counts is the TRA/direct case; explicit all-zero counts book nothing.
	if total == 0 && len(counts) != 0 {
		return nil, _oops.Errorf("at least one ticket is required")
	}
	return counts, nil
}

func collectTicketCounts(c *gin.Context) (map[string]int, int, error) {
	counts := make(map[string]int, len(_thsrTicketParams))
	total := 0
	for category := range _thsrTicketParams {
		raw := strings.TrimSpace(c.Query(category + "_ticket"))
		if raw == "" {
			continue
		}
		n, err := parseTicketCount(category, raw)
		if err != nil {
			return nil, 0, err
		}
		counts[category] = n
		total += n
	}
	return counts, total, nil
}

func parseTicketCount(category, raw string) (int, error) {
	n, err := strconv.Atoi(raw)
	if err != nil || !ticketCountInRange(n, 0, _maxTicketsPerCategory) {
		return 0, _oops.With("category", category).With("max", _maxTicketsPerCategory).Errorf("ticket count must be an integer within the allowed range")
	}
	return n, nil
}

// route selects the upstream client and resource path for an (agency, kind)
// pair. kind is the deeplink variant: "direct" (App Link → opens the operator
// app if installed) or "web" (→ pre-filled booking web page).
func (b *BookingProxy) route(agency, kind string) (*resty.Client, string, bool) {
	if kind != "web" && kind != "direct" {
		return nil, "", false
	}
	client, ok := map[string]*resty.Client{"tra": b.tra, "hsr": b.thsr}[agency]
	if !ok {
		return nil, "", false
	}
	return client, "/booking/deeplink/" + kind + "/" + agency, true
}

// bookingRequest is one booking exchange in our own vocabulary. The upstream
// spelling of every field differs per (agency, kind), so that mapping lives in
// bookingParams instead of being baked into the caller.
type bookingRequest struct {
	agency   string
	kind     string
	start    string
	end      string
	date     string // yyyy-mm-dd
	time     string // hh:mm
	train    string
	carriage string         // "Y" standard, "J" business — THSR web only
	tickets  map[string]int // passenger category → count — THSR web only

	// TRA web takes a single quantity plus its own ticket_type, which is a
	// booking class (1 一般 / 2 騰雲座艙 / 3 兩鐵) — not THSR's ticket_type,
	// which is the trip type. Same parameter name, unrelated meanings.
	traClass int
	traCount int
}

// TRA web booking classes and its per-order ticket ceiling.
const (
	_traClassStandard = 1
	_traClassMax      = 3
	_traCountMax      = 9
)

// _thsrTicketParams maps a passenger category to its TDX parameter. THSR takes
// one count parameter per category rather than a single quantity, and only the
// /web/hsr variant accepts them at all.
var _thsrTicketParams = map[string]string{
	"adult":    "adult_ticket",
	"child":    "children_ticket",
	"disabled": "disabled_ticket",
	"senior":   "senior_ticket",
	"student":  "student_ticket",
}

func bookingParams(r bookingRequest) map[string]string {
	q := make(map[string]string, 2)
	q["start_station"] = r.start
	q["end_station"] = r.end
	if r.kind == "web" {
		return webBookingParams(r, q)
	}
	return directBookingParams(r, q)
}

func webBookingParams(r bookingRequest, q map[string]string) map[string]string {
	if r.agency == "hsr" {
		return thsrWebBookingParams(r, q)
	}
	if r.agency == "tra" {
		return traWebBookingParams(r, q)
	}
	return directBookingParams(r, q)
}

func directBookingParams(r bookingRequest, q map[string]string) map[string]string {
	q["train_date"] = r.date
	if r.agency == "hsr" {
		q["train_time"] = r.time
	}
	q["train_number"] = r.train
	return q
}

func thsrWebBookingParams(r bookingRequest, q map[string]string) map[string]string {
	q["departure_date"] = strings.ReplaceAll(r.date, "-", "")
	// A 3-digit train number must be zero-padded to 4.
	q["departure_number"] = fmt.Sprintf("%04s", r.train)
	q["ticket_type"] = "S"
	carriage := r.carriage
	if carriage != "J" {
		carriage = "Y"
	}
	q["carriage_type"] = carriage
	for category, param := range _thsrTicketParams {
		q[param] = strconv.Itoa(r.tickets[category])
	}
	return q
}

func traWebBookingParams(r bookingRequest, q map[string]string) map[string]string {
	// Same fields as /direct/tra under different names: the date keeps its
	// yyyy-mm-dd form here (unlike THSR's web variant) but the train number
	// moves to departure_number.
	q["departure_date"] = r.date
	q["departure_number"] = r.train
	class := validTicketCountOr(r.traClass, _traClassStandard, _traClassMax, _traClassStandard)
	q["ticket_type"] = strconv.Itoa(class)
	count := validTicketCountOr(r.traCount, 1, _traCountMax, 1)
	q["ticket_count"] = strconv.Itoa(count)
	return q
}

func validTicketCountOr(value, lo, hi, fallback int) int {
	if !ticketCountInRange(value, lo, hi) {
		return fallback
	}
	return value
}

func (b *BookingProxy) exchange(ctx context.Context, client *resty.Client, resource string, r bookingRequest) (string, string, error) {
	var body tdxBookingResponse
	res, err := client.R().
		SetContext(ctx).
		SetQueryParams(bookingParams(r)).
		SetResult(&body).
		Get(resource)
	if err != nil {
		return "", "", err
	}
	if !bookingExchangeSucceeded(res, body) {
		return "", "", _oops.With("detail", bookingDetail(res, body)).Errorf("tdx booking exchange failed")
	}
	return body.Data.Deeplink, body.Data.Expired, nil
}

func bookingExchangeSucceeded(response *resty.Response, body tdxBookingResponse) bool {
	return !response.IsError() && body.Result == "success" && body.Data.Deeplink != ""
}

func HandleBookingDeeplink(booking *BookingProxy) gin.HandlerFunc {
	return func(c *gin.Context) {
		if booking == nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"error": "booking unavailable"})
			return
		}
		booking.handle(c)
	}
}

func (booking *BookingProxy) handle(c *gin.Context) {
	agency := strings.ToLower(strings.TrimSpace(c.Query("agency")))
	kind := strings.ToLower(strings.TrimSpace(c.Query("kind")))
	client, resource, ok := booking.route(agency, kind)
	if !ok {
		c.JSON(http.StatusBadRequest, gin.H{"error": "agency must be tra|hsr and kind must be web|direct"})
		return
	}
	req, err := parseBookingRequest(c, agency, kind)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	url, expired, err := booking.exchange(c.Request.Context(), client, resource, req)
	if err != nil {
		zap.S().Errorw("failed",
			"component", "booking",
			"action", "exchange",
			"event", "failed",
			"agency", agency,
			"kind", kind,
			"start", req.start,
			"end", req.end,
			"date", req.date,
			"time", req.time,
			"train", req.train,
			"err", err,
		)
		writeBookingFailure(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"url": url, "expired": expired})
}

func writeBookingFailure(c *gin.Context, err error) {
	if shared.IsTDXAuthError(err) {
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": "booking unavailable", "reason": "auth"})
		return
	}
	c.JSON(http.StatusBadGateway, gin.H{"error": "booking upstream failed", "reason": "upstream"})
}

func parseBookingRequest(c *gin.Context, agency, kind string) (bookingRequest, error) {
	req := bookingRequest{
		agency:   agency,
		kind:     kind,
		start:    strings.TrimSpace(c.Query("start_station")),
		end:      strings.TrimSpace(c.Query("end_station")),
		date:     strings.TrimSpace(c.Query("train_date")),
		time:     strings.TrimSpace(c.Query("train_time")),
		train:    strings.TrimSpace(c.Query("train_number")),
		carriage: strings.ToUpper(strings.TrimSpace(c.Query("carriage_type"))),
	}
	if err := validateBookingJourney(req); err != nil {
		return bookingRequest{}, err
	}
	if err := validateBookingTrain(req.train); err != nil {
		return bookingRequest{}, err
	}
	return parseBookingPassengers(c, req)
}

func validateBookingTrain(train string) error {
	if n, err := strconv.Atoi(train); err != nil || n <= 0 {
		return errors.New("train_number must be a positive integer")
	}
	return nil
}

func parseBookingPassengers(c *gin.Context, req bookingRequest) (bookingRequest, error) {
	tickets, err := parseTicketCounts(c)
	if err != nil {
		return bookingRequest{}, err
	}
	req.tickets = tickets
	if req.traClass, err = queryIntInRange(c, "ticket_type", _traClassStandard, _traClassStandard, _traClassMax); err != nil {
		return bookingRequest{}, err
	}
	if req.traCount, err = queryIntInRange(c, "ticket_count", 1, 1, _traCountMax); err != nil {
		return bookingRequest{}, err
	}
	return req, nil
}

func bookingJourneyPresent(req bookingRequest) bool {
	return req.start != "" && req.end != "" && _trainDatePattern.MatchString(req.date)
}

func validateBookingJourney(req bookingRequest) error {
	if !bookingJourneyPresent(req) {
		return errors.New("missing or malformed start_station/end_station/train_date")
	}
	// THSR requires train_time and TRA takes none, so it is required exactly
	// where it is used — failing here beats an upstream rejection whose
	// message the app can do nothing with.
	if req.agency == "hsr" && !_trainTimePattern.MatchString(req.time) {
		return errors.New("train_time must be hh:mm for hsr")
	}
	return nil
}
