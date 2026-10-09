package main

import (
	"cmp"
	"context"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"go.uber.org/zap"
)

const (
	// _outboxClaim is how long a claimed row is held. A worker that dies
	// mid-send leaves the claim to expire and the row goes out again.
	_outboxClaim = 2 * time.Minute
	// _outboxMaxAttempts and _outboxMaxAge bound retries: an alert that has
	// failed this often, or is this old, would only reach riders after the
	// disruption it describes.
	_outboxMaxAttempts = 5
	_outboxMaxAge      = 24 * time.Hour
	// _outboxRetention keeps rows, and so their dedupe keys, this long. A
	// republished alert inside the window never notifies twice.
	_outboxRetention = 7 * 24 * time.Hour
	_outboxBatch     = 50
)

// outboxDB is the narrow surface the consumer needs; *pgxpool.Pool in production.
type outboxDB interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// routeAlerter sends one route alert to its subscribers; *notify.Dispatcher.
type routeAlerter interface {
	RouteAlert(ctx context.Context, routeType, routeKey, body string)
}

type outboxRow struct {
	id                        int64
	routeType, routeKey, body string
}

// drainRouteAlertOutbox claims a batch of pending alerts, sends each and marks
// it processed. SKIP LOCKED keeps two workers from claiming the same row.
func drainRouteAlertOutbox(ctx context.Context, db outboxDB, alerter routeAlerter) (int, error) {
	rows, err := db.Query(ctx, `
		UPDATE route_alert_outbox
		SET claimed_until = now() + make_interval(secs => $1), attempts = attempts + 1
		WHERE id IN (
			SELECT id FROM route_alert_outbox
			WHERE processed_at IS NULL
			  AND attempts < $2
			  AND created_at > now() - make_interval(secs => $3)
			  AND (claimed_until IS NULL OR claimed_until < now())
			ORDER BY id
			LIMIT $4
			FOR UPDATE SKIP LOCKED)
		RETURNING id, route_type, route_key, body`,
		_outboxClaim.Seconds(), _outboxMaxAttempts, _outboxMaxAge.Seconds(), _outboxBatch)
	if err != nil {
		return 0, _oops.Wrapf(err, "claim route alerts")
	}
	claimed, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (outboxRow, error) {
		var o outboxRow
		err := r.Scan(&o.id, &o.routeType, &o.routeKey, &o.body)
		return o, err
	})
	if err != nil {
		return 0, _oops.Wrapf(err, "scan claimed route alerts")
	}
	// UPDATE ... RETURNING has no defined order; alerts go out in arrival order.
	slices.SortFunc(claimed, func(a, b outboxRow) int { return cmp.Compare(a.id, b.id) })
	for _, o := range claimed {
		alerter.RouteAlert(ctx, o.routeType, o.routeKey, o.body)
		if _, err := db.Exec(ctx, `UPDATE route_alert_outbox SET processed_at = now() WHERE id = $1`, o.id); err != nil {
			return len(claimed), _oops.With("id", o.id).Wrapf(err, "mark route alert processed")
		}
	}
	return len(claimed), nil
}

func pruneRouteAlertOutbox(ctx context.Context, db outboxDB) error {
	if _, err := db.Exec(ctx, `DELETE FROM route_alert_outbox WHERE created_at < now() - make_interval(secs => $1)`,
		_outboxRetention.Seconds()); err != nil {
		return _oops.Wrapf(err, "prune route alert outbox")
	}
	zap.S().Infow("pruned", "component", "outbox", "action", "prune", "event", "pruned")
	return nil
}
