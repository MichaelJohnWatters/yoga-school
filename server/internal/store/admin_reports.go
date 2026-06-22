package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// AdminReports is what GET /admin/reports returns. Kept as the combined
// payload for back-compat; new code should use the focused per-report
// endpoints (/admin/reports/revenue, /attendance, /instructor-pay) so the
// manager dashboard can poll at different cadences without dragging the
// other reports along.
type AdminReports struct {
	RevenueMonth    ReportMonthRevenue    `json:"revenue_month"`
	AvgOccupancyPct int                   `json:"avg_occupancy_pct"`
	NoShowRatePct   int                   `json:"no_show_rate_pct"`
	RevenueByWeek   []ReportWeekRevenue   `json:"revenue_by_week"`
	InstructorPay   []ReportInstructorPay `json:"instructor_pay"`
}

// ---- Focused per-report payloads -----------------------------------------

// RevenueReport is what GET /admin/reports/revenue returns.
type RevenueReport struct {
	Month  ReportMonthRevenue  `json:"month"`
	ByWeek []ReportWeekRevenue `json:"by_week"`
}

// AttendanceReport is what GET /admin/reports/attendance returns.
type AttendanceReport struct {
	AvgOccupancyPct int `json:"avg_occupancy_pct"`
	NoShowRatePct   int `json:"no_show_rate_pct"`
}

// InstructorPayReport is what GET /admin/reports/instructor-pay returns.
type InstructorPayReport struct {
	Rows []ReportInstructorPay `json:"rows"`
}

// RevenueReportFor returns just the revenue subset. The current impl
// delegates to the combined computation — fine at studio scale; revisit
// with focused queries when polling cadence diverges.
func (s *Store) RevenueReportFor(ctx context.Context, studioID string) (*RevenueReport, error) {
	full, err := s.AdminReportsFor(ctx, studioID)
	if err != nil {
		return nil, err
	}
	return &RevenueReport{Month: full.RevenueMonth, ByWeek: full.RevenueByWeek}, nil
}

// AttendanceReportFor returns just the attendance subset.
func (s *Store) AttendanceReportFor(ctx context.Context, studioID string) (*AttendanceReport, error) {
	full, err := s.AdminReportsFor(ctx, studioID)
	if err != nil {
		return nil, err
	}
	return &AttendanceReport{
		AvgOccupancyPct: full.AvgOccupancyPct,
		NoShowRatePct:   full.NoShowRatePct,
	}, nil
}

// InstructorPayReportFor returns just the per-instructor pay rows.
func (s *Store) InstructorPayReportFor(ctx context.Context, studioID string) (*InstructorPayReport, error) {
	full, err := s.AdminReportsFor(ctx, studioID)
	if err != nil {
		return nil, err
	}
	return &InstructorPayReport{Rows: full.InstructorPay}, nil
}

// ---- Range-scoped reports (time selection) --------------------------------
//
// These power the manager's date-range picker. The no-arg *ReportFor helpers
// above keep their original default windows for back-compat (revenue =
// current month + last 12 weeks, no-show = lifetime); the *Range variants
// honour an explicit [from, to) window expressed in studio-local dates.

// maxReportBuckets caps how many granularity buckets a single revenue report
// can return so a "daily over five years" request can't fan out into
// thousands of aggregate queries.
const maxReportBuckets = 400

// bucketRange is one [start, end) sub-window of a report range.
type bucketRange struct {
	start, end time.Time
}

// bucketRanges splits [from, to) into sub-windows at the requested
// granularity ("day" | "week" | "month"; anything else falls back to week),
// clamping the final bucket to `to`.
func bucketRanges(from, to time.Time, granularity string, loc *time.Location) []bucketRange {
	out := []bucketRange{}
	for cur := from; cur.Before(to); {
		var next time.Time
		switch granularity {
		case "day":
			next = startOfDayIn(cur, loc).AddDate(0, 0, 1)
		case "month":
			next = startOfMonthIn(cur, loc).AddDate(0, 1, 0)
		default: // week
			next = cur.AddDate(0, 0, 7)
		}
		if !next.After(cur) { // defensive: never stall
			next = cur.AddDate(0, 0, 1)
		}
		if next.After(to) {
			next = to
		}
		out = append(out, bucketRange{start: cur, end: next})
		cur = next
		if len(out) > maxReportBuckets {
			break
		}
	}
	return out
}

// RevenueReportRange returns the revenue summary over [from, to) plus a series
// of buckets at the chosen granularity. Bucket starts are surfaced in the
// existing ByWeek.WeekStart field (the client renders them generically).
func (s *Store) RevenueReportRange(ctx context.Context, studioID string, from, to time.Time, granularity string) (*RevenueReport, error) {
	loc := s.StudioLocation(ctx, studioID)
	out := &RevenueReport{}

	var currency string
	if err := s.db.QueryRowContext(ctx,
		`SELECT currency FROM studios WHERE id = ?`, studioID,
	).Scan(&currency); err != nil {
		return nil, err
	}
	out.Month.Currency = currency
	out.Month.MonthLabel = rangeLabel(from, to, loc)

	// Whole-period summary.
	if err := s.aggregateRevenueRange(ctx, studioID,
		from.UTC().Format(time.RFC3339), to.UTC().Format(time.RFC3339),
		func(card, cash, gross, disc int) {
			out.Month.CardMinor = card
			out.Month.CashMinor = cash
			out.Month.TotalMinor = card + cash
			out.Month.GrossMinor = gross
			out.Month.DiscountMinor = disc
		},
	); err != nil {
		return nil, err
	}

	buckets := bucketRanges(from, to, granularity, loc)
	if len(buckets) > maxReportBuckets {
		return nil, fmt.Errorf("range too large for %q granularity", granularity)
	}
	out.ByWeek = make([]ReportWeekRevenue, len(buckets))
	for i, b := range buckets {
		out.ByWeek[i].WeekStart = b.start.In(loc).Format("2006-01-02")
		if err := s.aggregateRevenueRange(ctx, studioID,
			b.start.UTC().Format(time.RFC3339), b.end.UTC().Format(time.RFC3339),
			func(card, cash, gross, disc int) {
				out.ByWeek[i].CardMinor = card
				out.ByWeek[i].CashMinor = cash
				out.ByWeek[i].GrossMinor = gross
				out.ByWeek[i].DiscountMinor = disc
			},
		); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// AttendanceReportRange computes occupancy + no-show over past classes whose
// start falls in [from, to). Unlike AttendanceReportFor the no-show rate is
// windowed to the range rather than lifetime.
func (s *Store) AttendanceReportRange(ctx context.Context, studioID string, from, to time.Time) (*AttendanceReport, error) {
	out := &AttendanceReport{}
	fromS := from.UTC().Format(time.RFC3339)
	toS := to.UTC().Format(time.RFC3339)

	var totalCap, booked sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `
		SELECT COALESCE(SUM(c.capacity), 0),
		       COALESCE(SUM((SELECT COUNT(*) FROM bookings b
		                       WHERE b.class_id = c.id
		                         AND b.status IN ('booked','attended'))), 0)
		  FROM classes c
		 WHERE c.studio_id = ?
		   AND c.status    = 'scheduled'
		   AND c.starts_at >= ? AND c.starts_at < ?
		   AND c.starts_at <  strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
		studioID, fromS, toS,
	).Scan(&totalCap, &booked); err != nil {
		return nil, err
	}
	if totalCap.Int64 > 0 {
		out.AvgOccupancyPct = int(booked.Int64 * 100 / totalCap.Int64)
	}

	var totalPast, noShows int
	if err := s.db.QueryRowContext(ctx, `
		SELECT
		  (SELECT COUNT(*) FROM bookings b
		     JOIN classes c ON c.id = b.class_id
		    WHERE b.studio_id = ?
		      AND c.starts_at >= ? AND c.starts_at < ?
		      AND c.starts_at <  strftime('%Y-%m-%dT%H:%M:%fZ','now')
		      AND b.status IN ('booked','attended','no_show')),
		  (SELECT COUNT(*) FROM bookings b
		     JOIN classes c ON c.id = b.class_id
		    WHERE b.studio_id = ?
		      AND c.starts_at >= ? AND c.starts_at < ?
		      AND c.starts_at <  strftime('%Y-%m-%dT%H:%M:%fZ','now')
		      AND b.status = 'no_show')`,
		studioID, fromS, toS, studioID, fromS, toS,
	).Scan(&totalPast, &noShows); err != nil {
		return nil, err
	}
	if totalPast > 0 {
		out.NoShowRatePct = noShows * 100 / totalPast
	}
	return out, nil
}

// InstructorPayReportRange counts each instructor's past classes whose start
// falls in [from, to) and multiplies by their per-class rate.
func (s *Store) InstructorPayReportRange(ctx context.Context, studioID string, from, to time.Time) (*InstructorPayReport, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT i.id, i.full_name, i.instructor_pay_rate_minor,
		       COUNT(c.id) AS classes_taught
		  FROM users i
		  LEFT JOIN classes c
		         ON c.instructor_id = i.id
		        AND c.studio_id     = ?
		        AND c.status        = 'scheduled'
		        AND c.starts_at >= ? AND c.starts_at < ?
		        AND c.starts_at <  strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE i.studio_id = ? AND i.role = 'instructor'
		 GROUP BY i.id, i.full_name, i.instructor_pay_rate_minor
		 ORDER BY classes_taught DESC, i.full_name ASC`,
		studioID, from.UTC().Format(time.RFC3339), to.UTC().Format(time.RFC3339), studioID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := &InstructorPayReport{Rows: []ReportInstructorPay{}}
	for rows.Next() {
		var (
			p         ReportInstructorPay
			rateMinor sql.NullInt64
		)
		if err := rows.Scan(&p.InstructorID, &p.FullName, &rateMinor, &p.ClassesTaught); err != nil {
			return nil, err
		}
		rate := defaultRatePerClassMinor
		if rateMinor.Valid {
			rate = int(rateMinor.Int64)
		}
		p.RateMinor = rate
		p.PayMinor = p.ClassesTaught * rate
		out.Rows = append(out.Rows, p)
	}
	return out, rows.Err()
}

// rangeLabel renders a [from, to) window (to exclusive) as a compact
// human label like "1 – 30 Jun 2026" or "28 May – 3 Jun 2026".
func rangeLabel(from, to time.Time, loc *time.Location) string {
	mon := []string{"Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	fl := from.In(loc)
	tl := to.In(loc).AddDate(0, 0, -1) // inclusive last day
	if tl.Before(fl) {
		tl = fl
	}
	if fl.Year() == tl.Year() && fl.Month() == tl.Month() {
		return fmt.Sprintf("%d – %d %s %d", fl.Day(), tl.Day(), mon[int(fl.Month())-1], fl.Year())
	}
	if fl.Year() == tl.Year() {
		return fmt.Sprintf("%d %s – %d %s %d",
			fl.Day(), mon[int(fl.Month())-1], tl.Day(), mon[int(tl.Month())-1], fl.Year())
	}
	return fmt.Sprintf("%d %s %d – %d %s %d",
		fl.Day(), mon[int(fl.Month())-1], fl.Year(),
		tl.Day(), mon[int(tl.Month())-1], tl.Year())
}

type ReportMonthRevenue struct {
	TotalMinor    int    `json:"total_minor"`
	CardMinor     int    `json:"card_minor"`
	CashMinor     int    `json:"cash_minor"`
	GrossMinor    int    `json:"gross_minor"`
	DiscountMinor int    `json:"discount_minor"`
	Currency      string `json:"currency"`
	MonthLabel    string `json:"month_label"`
}

type ReportWeekRevenue struct {
	WeekStart     string `json:"week_start"` // YYYY-MM-DD (Monday)
	CardMinor     int    `json:"card_minor"`
	CashMinor     int    `json:"cash_minor"`
	GrossMinor    int    `json:"gross_minor"`
	DiscountMinor int    `json:"discount_minor"`
}

type ReportInstructorPay struct {
	InstructorID  string `json:"instructor_id"`
	FullName      string `json:"full_name"`
	ClassesTaught int    `json:"classes_taught"`
	// Per-class rate that was applied. Surfacing it lets the dashboard
	// show "£35/class · 12 classes · £420" without the client guessing.
	RateMinor int `json:"rate_minor"`
	PayMinor  int `json:"pay_minor"`
}

// defaultRatePerClassMinor is the fallback per-class pay rate used when an
// instructor's row has no rate set. Studios that want a different default
// should set the column on each instructor; the admin staff CRUD exposes it.
const defaultRatePerClassMinor = 3500 // £35

func (s *Store) AdminReportsFor(ctx context.Context, studioID string) (*AdminReports, error) {
	loc := s.StudioLocation(ctx, studioID)
	now := time.Now()
	// All month/week anchors here are computed in studio time so a Sydney
	// studio's "May" runs Sydney May 1 to Sydney May 31 — matching how
	// the manager thinks about their own books.
	monthStart := startOfMonthIn(now, loc)

	out := &AdminReports{}

	// Currency.
	var currency string
	if err := s.db.QueryRowContext(ctx,
		`SELECT currency FROM studios WHERE id = ?`, studioID,
	).Scan(&currency); err != nil {
		return nil, err
	}
	out.RevenueMonth.Currency = currency
	const monthNames = "January February March April May June July August September October November December"
	mn := []string{"January", "February", "March", "April", "May", "June",
		"July", "August", "September", "October", "November", "December"}
	monthInStudio := now.In(loc)
	out.RevenueMonth.MonthLabel = mn[int(monthInStudio.Month())-1] + " " + itoa(monthInStudio.Year())
	_ = monthNames

	// Month revenue split by method bucket.
	if err := s.aggregateRevenueRange(ctx, studioID,
		monthStart.UTC().Format(time.RFC3339),
		monthStart.AddDate(0, 1, 0).UTC().Format(time.RFC3339),
		func(card, cash, gross, disc int) {
			out.RevenueMonth.CardMinor = card
			out.RevenueMonth.CashMinor = cash
			out.RevenueMonth.TotalMinor = card + cash
			out.RevenueMonth.GrossMinor = gross
			out.RevenueMonth.DiscountMinor = disc
		},
	); err != nil {
		return nil, err
	}

	// Average occupancy this month over past classes.
	var totalCap, booked sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `
		SELECT COALESCE(SUM(c.capacity), 0),
		       COALESCE(SUM((SELECT COUNT(*) FROM bookings b
		                       WHERE b.class_id = c.id
		                         AND b.status IN ('booked','attended'))), 0)
		  FROM classes c
		 WHERE c.studio_id = ?
		   AND c.status    = 'scheduled'
		   AND c.starts_at >= ?
		   AND c.starts_at <  strftime('%Y-%m-%dT%H:%M:%fZ','now')`,
		studioID, monthStart.UTC().Format(time.RFC3339),
	).Scan(&totalCap, &booked); err != nil {
		return nil, err
	}
	if totalCap.Int64 > 0 {
		out.AvgOccupancyPct = int(booked.Int64 * 100 / totalCap.Int64)
	}

	// No-show rate over all past bookings (lifetime; could be scoped).
	var totalPast, noShows int
	if err := s.db.QueryRowContext(ctx, `
		SELECT
		  (SELECT COUNT(*) FROM bookings b
		     JOIN classes c ON c.id = b.class_id
		    WHERE b.studio_id = ?
		      AND c.starts_at < strftime('%Y-%m-%dT%H:%M:%fZ','now')
		      AND b.status IN ('booked','attended','no_show')),
		  (SELECT COUNT(*) FROM bookings b
		     JOIN classes c ON c.id = b.class_id
		    WHERE b.studio_id = ?
		      AND c.starts_at < strftime('%Y-%m-%dT%H:%M:%fZ','now')
		      AND b.status = 'no_show')`,
		studioID, studioID,
	).Scan(&totalPast, &noShows); err != nil {
		return nil, err
	}
	if totalPast > 0 {
		out.NoShowRatePct = noShows * 100 / totalPast
	}

	// Per-week revenue, last 12 weeks anchored on Monday in studio time.
	monday := mondayOfIn(now, loc)
	out.RevenueByWeek = make([]ReportWeekRevenue, 12)
	for i := 0; i < 12; i++ {
		ws := monday.AddDate(0, 0, -7*(11-i))
		we := ws.AddDate(0, 0, 7)
		out.RevenueByWeek[i].WeekStart = ws.Format("2006-01-02")
		if err := s.aggregateRevenueRange(ctx, studioID,
			ws.UTC().Format(time.RFC3339),
			we.UTC().Format(time.RFC3339),
			func(card, cash, gross, disc int) {
				out.RevenueByWeek[i].CardMinor = card
				out.RevenueByWeek[i].CashMinor = cash
				out.RevenueByWeek[i].GrossMinor = gross
				out.RevenueByWeek[i].DiscountMinor = disc
			},
		); err != nil {
			return nil, err
		}
	}

	// Instructor pay this month (classes counted = scheduled & past, by
	// instructor). Rate is per-instructor when set; otherwise the studio's
	// default carries through.
	rows, err := s.db.QueryContext(ctx, `
		SELECT i.id, i.full_name, i.instructor_pay_rate_minor,
		       COUNT(c.id) AS classes_taught
		  FROM users i
		  LEFT JOIN classes c
		         ON c.instructor_id = i.id
		        AND c.studio_id     = ?
		        AND c.status        = 'scheduled'
		        AND c.starts_at >= ?
		        AND c.starts_at <  strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE i.studio_id = ? AND i.role = 'instructor'
		 GROUP BY i.id, i.full_name, i.instructor_pay_rate_minor
		 ORDER BY classes_taught DESC, i.full_name ASC`,
		studioID, monthStart.UTC().Format(time.RFC3339), studioID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out.InstructorPay = []ReportInstructorPay{}
	for rows.Next() {
		var (
			p         ReportInstructorPay
			rateMinor sql.NullInt64
		)
		if err := rows.Scan(&p.InstructorID, &p.FullName, &rateMinor, &p.ClassesTaught); err != nil {
			return nil, err
		}
		rate := defaultRatePerClassMinor
		if rateMinor.Valid {
			rate = int(rateMinor.Int64)
		}
		p.RateMinor = rate
		p.PayMinor = p.ClassesTaught * rate
		out.InstructorPay = append(out.InstructorPay, p)
	}
	return out, rows.Err()
}

// aggregateRevenueRange sums completed purchases in [from, to) and calls cb
// with (cardMinor, cashMinor, grossMinor, discountMinor). Anything not cash
// counts as card revenue; 'comp' rows contribute zero per design (free
// passes don't count toward card/cash, but their list price still flows
// through gross so the discount-given line stays honest).
func (s *Store) aggregateRevenueRange(ctx context.Context, studioID, from, to string, cb func(card, cash, gross, disc int)) error {
	rows, err := s.db.QueryContext(ctx, `
		SELECT payment_method,
		       COALESCE(SUM(amount_minor), 0),
		       COALESCE(SUM(list_price_minor), 0),
		       COALESCE(SUM(discount_minor), 0)
		  FROM purchases
		 WHERE studio_id = ? AND status = 'completed'
		   AND created_at >= ? AND created_at < ?
		 GROUP BY payment_method`,
		studioID, from, to,
	)
	if err != nil {
		return err
	}
	defer rows.Close()
	card, cash, gross, disc := 0, 0, 0, 0
	for rows.Next() {
		var method string
		var amt, g, d int
		if err := rows.Scan(&method, &amt, &g, &d); err != nil {
			return err
		}
		gross += g
		disc += d
		switch method {
		case "cash":
			cash += amt
		case "comp":
			// no card/cash contribution
		default:
			card += amt
		}
	}
	cb(card, cash, gross, disc)
	return rows.Err()
}

// itoa avoids strconv import noise for a single use.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
