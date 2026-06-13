package store

import (
	"context"
	"database/sql"
	"time"
)

// AdminReports is what GET /admin/reports returns.
type AdminReports struct {
	RevenueMonth     ReportMonthRevenue  `json:"revenue_month"`
	AvgOccupancyPct  int                 `json:"avg_occupancy_pct"`
	NoShowRatePct    int                 `json:"no_show_rate_pct"`
	RevenueByWeek    []ReportWeekRevenue `json:"revenue_by_week"`
	InstructorPay    []ReportInstructorPay `json:"instructor_pay"`
}

type ReportMonthRevenue struct {
	TotalMinor int    `json:"total_minor"`
	CardMinor  int    `json:"card_minor"`
	CashMinor  int    `json:"cash_minor"`
	Currency   string `json:"currency"`
	MonthLabel string `json:"month_label"`
}

type ReportWeekRevenue struct {
	WeekStart string `json:"week_start"` // YYYY-MM-DD (Monday)
	CardMinor int    `json:"card_minor"`
	CashMinor int    `json:"cash_minor"`
}

type ReportInstructorPay struct {
	InstructorID   string `json:"instructor_id"`
	FullName       string `json:"full_name"`
	ClassesTaught  int    `json:"classes_taught"`
	PayMinor       int    `json:"pay_minor"`
}

// Per-class instructor pay rate (minor units of studio currency). Hardcoded
// for now; production would store per-instructor rates.
const _defaultRatePerClassMinor = 3500 // £35

func (s *Store) AdminReportsFor(ctx context.Context, studioID string) (*AdminReports, error) {
	now := time.Now().UTC()
	monthStart := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)

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
	out.RevenueMonth.MonthLabel = mn[int(now.Month())-1] + " " + itoa(now.Year())
	_ = monthNames

	// Month revenue split by method bucket.
	if err := s.aggregateRevenueRange(ctx, studioID,
		monthStart.Format(time.RFC3339),
		monthStart.AddDate(0, 1, 0).Format(time.RFC3339),
		func(card, cash int) {
			out.RevenueMonth.CardMinor = card
			out.RevenueMonth.CashMinor = cash
			out.RevenueMonth.TotalMinor = card + cash
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
		studioID, monthStart.Format(time.RFC3339),
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

	// Per-week revenue, last 12 weeks anchored on Monday.
	monday := mondayOf(now)
	out.RevenueByWeek = make([]ReportWeekRevenue, 12)
	for i := 0; i < 12; i++ {
		ws := monday.AddDate(0, 0, -7*(11-i))
		we := ws.AddDate(0, 0, 7)
		out.RevenueByWeek[i].WeekStart = ws.Format("2006-01-02")
		if err := s.aggregateRevenueRange(ctx, studioID,
			ws.Format(time.RFC3339),
			we.Format(time.RFC3339),
			func(card, cash int) {
				out.RevenueByWeek[i].CardMinor = card
				out.RevenueByWeek[i].CashMinor = cash
			},
		); err != nil {
			return nil, err
		}
	}

	// Instructor pay this month (classes counted = scheduled & past, by instructor).
	rows, err := s.db.QueryContext(ctx, `
		SELECT i.id, i.full_name,
		       COUNT(c.id) AS classes_taught
		  FROM users i
		  LEFT JOIN classes c
		         ON c.instructor_id = i.id
		        AND c.studio_id     = ?
		        AND c.status        = 'scheduled'
		        AND c.starts_at >= ?
		        AND c.starts_at <  strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE i.studio_id = ? AND i.role = 'instructor'
		 GROUP BY i.id, i.full_name
		 ORDER BY classes_taught DESC, i.full_name ASC`,
		studioID, monthStart.Format(time.RFC3339), studioID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out.InstructorPay = []ReportInstructorPay{}
	for rows.Next() {
		var p ReportInstructorPay
		if err := rows.Scan(&p.InstructorID, &p.FullName, &p.ClassesTaught); err != nil {
			return nil, err
		}
		p.PayMinor = p.ClassesTaught * _defaultRatePerClassMinor
		out.InstructorPay = append(out.InstructorPay, p)
	}
	return out, rows.Err()
}

// aggregateRevenueRange sums completed purchases in [from, to) and calls cb
// with (cardMinor, cashMinor). Anything not cash counts as card revenue;
// 'comp' rows contribute zero per design (free passes don't count).
func (s *Store) aggregateRevenueRange(ctx context.Context, studioID, from, to string, cb func(card, cash int)) error {
	rows, err := s.db.QueryContext(ctx, `
		SELECT payment_method, COALESCE(SUM(amount_minor), 0)
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
	card, cash := 0, 0
	for rows.Next() {
		var method string
		var amt int
		if err := rows.Scan(&method, &amt); err != nil {
			return err
		}
		switch method {
		case "cash":
			cash += amt
		case "comp":
			// no revenue contribution
		default:
			card += amt
		}
	}
	cb(card, cash)
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
