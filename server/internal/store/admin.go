package store

import (
	"context"
	"database/sql"
	"time"
)

// AdminDashboard powers GET /admin/dashboard — see the design's KDashboard.
type AdminDashboard struct {
	Date               string            `json:"date"`
	OccupancyToday     AdminOccupancy    `json:"occupancy_today"`
	RevenueToday       AdminRevenueToday `json:"revenue_today"`
	NewBookingsToday   int               `json:"new_bookings_today"`
	UnmarkedAttendance int               `json:"unmarked_attendance_count"`
	ClassesToday       []ClassRow        `json:"classes_today"`
}

type AdminOccupancy struct {
	BookedSeats   int `json:"booked_seats"`
	TotalCapacity int `json:"total_capacity"`
	Percent       int `json:"percent"` // 0–100
}

type AdminRevenueToday struct {
	TotalMinor    int    `json:"total_minor"`
	CardMinor     int    `json:"card_minor"`
	CashMinor     int    `json:"cash_minor"`
	GrossMinor    int    `json:"gross_minor"`
	DiscountMinor int    `json:"discount_minor"`
	Currency      string `json:"currency"`
}

// AdminDashboardFor returns the dashboard payload for a given manager's
// studio. We use the manager's own ID as the "viewer" for ClassesToday so
// booking_state stays consistent with the rest of the API.
//
// "Today" is computed in the studio's timezone so a Tokyo studio rolls
// over at Tokyo's midnight, not UTC's.
func (s *Store) AdminDashboardFor(ctx context.Context, studioID, viewerID string) (*AdminDashboard, error) {
	loc := s.StudioLocation(ctx, studioID)
	now := time.Now()
	dayStart := startOfDayIn(now, loc)
	dayEnd := dayStart.Add(24 * time.Hour)
	yesterdayStart := dayStart.Add(-24 * time.Hour)

	out := &AdminDashboard{Date: dayStart.Format("2006-01-02")}

	// Occupancy: sum capacity vs sum non-cancelled bookings on today's classes.
	var totalCap, booked sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `
		SELECT COALESCE(SUM(c.capacity), 0),
		       COALESCE(SUM((SELECT COUNT(*) FROM bookings b
		                       WHERE b.class_id = c.id AND b.status = 'booked')), 0)
		  FROM classes c
		 WHERE c.studio_id = ?
		   AND c.status    = 'scheduled'
		   AND c.starts_at >= ? AND c.starts_at < ?`,
		studioID, dayStart.UTC().Format(time.RFC3339), dayEnd.UTC().Format(time.RFC3339),
	).Scan(&totalCap, &booked); err != nil {
		return nil, err
	}
	out.OccupancyToday.TotalCapacity = int(totalCap.Int64)
	out.OccupancyToday.BookedSeats = int(booked.Int64)
	if totalCap.Int64 > 0 {
		out.OccupancyToday.Percent = int(booked.Int64 * 100 / totalCap.Int64)
	}

	// Revenue today: completed purchases since dayStart.
	var currency string
	if err := s.db.QueryRowContext(ctx,
		`SELECT currency FROM studios WHERE id = ?`, studioID,
	).Scan(&currency); err != nil {
		return nil, err
	}
	out.RevenueToday.Currency = currency
	rows, err := s.db.QueryContext(ctx, `
		SELECT payment_method,
		       COALESCE(SUM(amount_minor), 0),
		       COALESCE(SUM(list_price_minor), 0),
		       COALESCE(SUM(discount_minor), 0)
		  FROM purchases
		 WHERE studio_id = ? AND status = 'completed'
		   AND created_at >= ?
		 GROUP BY payment_method`,
		studioID, dayStart.UTC().Format(time.RFC3339),
	)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var method string
		var amt, gross, disc int
		if err := rows.Scan(&method, &amt, &gross, &disc); err != nil {
			rows.Close()
			return nil, err
		}
		switch method {
		case "cash":
			out.RevenueToday.CashMinor += amt
		default:
			// 'card' or 'dev_stub' counted as card revenue.
			out.RevenueToday.CardMinor += amt
		}
		out.RevenueToday.TotalMinor += amt
		out.RevenueToday.GrossMinor += gross
		out.RevenueToday.DiscountMinor += disc
	}
	rows.Close()

	// New bookings created today.
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM bookings
		 WHERE studio_id = ? AND created_at >= ?`,
		studioID, dayStart.UTC().Format(time.RFC3339),
	).Scan(&out.NewBookingsToday); err != nil {
		return nil, err
	}

	// Unmarked attendance: past classes whose status is still 'scheduled'
	// (not cancelled) AND that have non-cancelled bookings still in 'booked'
	// (i.e. roster wasn't worked through). Looking back at yesterday only,
	// per the design's "2 classes from yesterday still have unmarked
	// attendance".
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(DISTINCT c.id)
		  FROM classes c
		  JOIN bookings b ON b.class_id = c.id
		 WHERE c.studio_id = ?
		   AND c.status    = 'scheduled'
		   AND c.starts_at >= ? AND c.starts_at < ?
		   AND b.status    = 'booked'`,
		studioID, yesterdayStart.UTC().Format(time.RFC3339), dayStart.UTC().Format(time.RFC3339),
	).Scan(&out.UnmarkedAttendance); err != nil {
		return nil, err
	}

	// Today's classes table.
	classes, err := s.ClassesForDay(ctx, studioID, viewerID, dayStart)
	if err != nil {
		return nil, err
	}
	if classes == nil {
		classes = []ClassRow{}
	}
	out.ClassesToday = classes
	return out, nil
}

// AdminClassesFor returns all scheduled classes in the date range [from, to)
// (UTC dates). Used by Schedule Week view.
func (s *Store) AdminClassesFor(ctx context.Context, studioID string, from, to time.Time) ([]ClassRow, error) {
	const q = `
		SELECT
			c.id, COALESCE(c.title,''),
			ct.id, ct.name, COALESCE(ct.discipline,''),
			i.id, i.full_name, i.photo_url,
			r.id, r.name, r.color,
			c.starts_at, c.ends_at, c.capacity,
			(SELECT COUNT(*) FROM bookings b
			    WHERE b.class_id = c.id AND b.status = 'booked') AS booked_count,
			NULL AS my_booking_id,
			c.recurrence_rule_id,
			c.enrollment_id,
			-- Messages in this class's group chat (series chat when the class
			-- recurs, else the one-off class chat). Drives the schedule's
			-- chat badge so busy class chats draw a manager's eye.
			(SELECT COUNT(*) FROM messages m
			   JOIN conversations cv ON cv.id = m.conversation_id
			  WHERE cv.kind = 'class' AND m.deleted_at IS NULL
			    AND ((c.recurrence_rule_id IS NOT NULL
			          AND cv.recurrence_rule_id = c.recurrence_rule_id)
			      OR (c.recurrence_rule_id IS NULL
			          AND cv.class_id = c.id))) AS chat_message_count
		FROM classes c
		JOIN class_types ct ON ct.id = c.class_type_id
		JOIN users i        ON i.id = c.instructor_id
		JOIN rooms r        ON r.id = c.room_id
		WHERE c.studio_id = ?
		  AND c.status    = 'scheduled'
		  AND c.starts_at >= ?
		  AND c.starts_at <  ?
		ORDER BY c.starts_at`
	rows, err := s.db.QueryContext(ctx, q, studioID,
		from.UTC().Format(time.RFC3339), to.UTC().Format(time.RFC3339))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ClassRow{}
	for rows.Next() {
		var (
			r            ClassRow
			myBooking    sql.NullString
			photoURL     sql.NullString
			ruleID       sql.NullString
			enrollmentID sql.NullString
			roomColor    sql.NullString
		)
		if err := rows.Scan(
			&r.ID, &r.Title,
			&r.ClassTypeID, &r.ClassTypeName, &r.Discipline,
			&r.InstructorID, &r.InstructorName, &photoURL,
			&r.RoomID, &r.RoomName, &roomColor,
			&r.StartsAt, &r.EndsAt, &r.Capacity,
			&r.BookedCount, &myBooking, &ruleID, &enrollmentID,
			&r.ChatMessageCount,
		); err != nil {
			return nil, err
		}
		if photoURL.Valid {
			s := photoURL.String
			r.InstructorPhotoURL = &s
		}
		if ruleID.Valid {
			s := ruleID.String
			r.RecurrenceRuleID = &s
		}
		if enrollmentID.Valid {
			s := enrollmentID.String
			r.EnrollmentID = &s
		}
		if roomColor.Valid && roomColor.String != "" {
			s := roomColor.String
			r.RoomColor = &s
		}
		start, _ := time.Parse(time.RFC3339, r.StartsAt)
		end, _ := time.Parse(time.RFC3339, r.EndsAt)
		r.DurationMinutes = int(end.Sub(start).Minutes())
		if r.BookedCount >= r.Capacity {
			r.BookingState = "full"
		} else {
			r.BookingState = "available"
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
