package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	fbauth "firebase.google.com/go/v4/auth"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/studio52/yoga-school/server/internal/auth"
	"github.com/studio52/yoga-school/server/internal/store"
)

type Server struct {
	store    *store.Store
	fbClient *fbauth.Client
	// verify resolves a bearer token to a Firebase identity. Defaults to the
	// real Firebase Admin SDK path; tests swap in a stub to avoid needing
	// a live emulator + signed token.
	verify func(ctx context.Context, idToken string) (*auth.Verified, error)
}

func NewServer(s *store.Store, fb *fbauth.Client) *Server {
	srv := &Server{store: s, fbClient: fb}
	srv.verify = func(ctx context.Context, idToken string) (*auth.Verified, error) {
		return auth.Verify(ctx, srv.fbClient, idToken)
	}
	return srv
}

func (s *Server) Routes() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(cors)

	r.Route("/api/v1", func(r chi.Router) {
		r.Use(s.auth)
		// Staff routes — instructor + manager + owner. Read-only schedule
		// and roster views, attendance marking, check-in scan, and a few
		// lookups instructors need to teach.
		r.Group(func(r chi.Router) {
			r.Use(s.requireStaff)
			r.Get("/admin/classes", s.handleAdminClasses)
			r.Get("/admin/classes/{id}/roster", s.handleAdminRoster)
			r.Post("/admin/bookings/{id}/attendance", s.handleMarkAttendance)
			r.Post("/admin/classes/{id}/promote", s.handlePromoteWaitlist)
			r.Post("/admin/checkin/scan", s.handleAdminCheckinScan)
			r.Get("/admin/class-types", s.handleAdminListClassTypes)
			r.Get("/admin/instructors", s.handleAdminListInstructors)
			r.Get("/admin/rooms", s.handleAdminListRooms)
			r.Get("/admin/class-templates", s.handleAdminListClassTemplates)
			r.Get("/admin/enrollments", s.handleAdminListEnrollments)
			r.Get("/admin/enrollments/{id}/roster", s.handleAdminSeriesRoster)
			r.Get("/admin/students", s.handleAdminListStudents)
			r.Get("/admin/students/{id}", s.handleAdminGetStudent)
		})

		// Manager routes — manager + owner only. Money mutators, config,
		// taxonomy mutations, reports, dashboard (includes revenue),
		// audit log, staff CRUD, promotions. Instructors get 403 here.
		r.Group(func(r chi.Router) {
			r.Use(s.requireManager)
			r.Get("/admin/dashboard", s.handleAdminDashboard)
			r.Get("/admin/audit", s.handleAdminAudit)
			r.Get("/admin/reports", s.handleAdminReports)
			r.Get("/admin/themes", s.handleListThemes)
			r.Post("/admin/themes", s.handleCreateTheme)
			r.Patch("/admin/themes/{id}", s.handleUpdateTheme)
			r.Post("/admin/themes/{id}/activate", s.handleActivateTheme)
			r.Patch("/admin/studio/config", s.handleUpdateStudioConfig)
			r.Get("/admin/products", s.handleAdminListProducts)
			r.Post("/admin/products", s.handleAdminCreateProduct)
			r.Patch("/admin/products/{id}", s.handleAdminUpdateProduct)
			r.Delete("/admin/products/{id}", s.handleAdminArchiveProduct)
			r.Post("/admin/class-types", s.handleAdminCreateClassType)
			r.Patch("/admin/class-types/{id}", s.handleAdminUpdateClassType)
			r.Post("/admin/classes", s.handleAdminCreateClass)
			r.Patch("/admin/classes/{id}", s.handleAdminUpdateClass)
			r.Delete("/admin/classes/{id}", s.handleAdminCancelClass)
			r.Post("/admin/class-templates", s.handleAdminCreateClassTemplate)
			r.Post("/admin/class-templates/{id}/undo", s.handleAdminUndoClassTemplate)
			r.Post("/admin/enrollments", s.handleAdminCreateSeries)
			r.Patch("/admin/enrollments/{id}", s.handleAdminUpdateEnrollment)
			r.Post("/admin/students/{id}/grant", s.handleAdminGrantPass)
			r.Post("/admin/students/{id}/entitlements/{eid}/adjust",
				s.handleAdminAdjustCredits)
			r.Post("/admin/entitlements/{id}/void", s.handleAdminVoidEntitlement)
			r.Get("/admin/staff", s.handleAdminListStaff)
			r.Post("/admin/staff", s.handleAdminCreateStaff)
			r.Patch("/admin/staff/{id}", s.handleAdminUpdateStaff)
			r.Get("/admin/promotions", s.handleAdminListPromotions)
			r.Post("/admin/promotions", s.handleAdminCreatePromotion)
			r.Patch("/admin/promotions/{id}", s.handleAdminUpdatePromotion)
			r.Delete("/admin/promotions/{id}", s.handleAdminArchivePromotion)
		})
		r.Get("/me", s.handleMe)
		r.Get("/studio/config", s.handleStudioConfig)
		r.Get("/classes", s.handleListClasses)
		r.Get("/classes/{id}", s.handleClassDetail)
		r.Get("/classes/{id}/eligible-entitlements", s.handleEligibleEntitlements)
		r.Get("/enrollments", s.handleListEnrollments)
		r.Get("/enrollments/{id}", s.handleEnrollmentDetail)
		r.Post("/enrollments/{id}/join", s.handleJoinEnrollment)
		r.Get("/bookings", s.handleListBookings)
		r.Post("/bookings", s.handleCreateBooking)
		r.Delete("/bookings/{id}", s.handleCancelBooking)
		r.Get("/products", s.handleListProducts)
		r.Get("/products/{id}", s.handleProductDetail)
		r.Post("/purchases", s.handleCreatePurchase)
		r.Get("/purchases", s.handleListPurchases)
		r.Get("/me/entitlements", s.handleMyEntitlements)
		r.Get("/me/attendance", s.handleMyAttendance)
		r.Get("/me/checkin-code", s.handleCheckInCode)
		r.Get("/me/notifications/feed", s.handleNotificationsFeed)
		r.Post("/me/notifications/{id}/read", s.handleMarkNotificationRead)
		r.Post("/me/notifications/read-all", s.handleMarkAllNotificationsRead)
		r.Post("/classes/{id}/waitlist", s.handleJoinWaitlist)
		r.Get("/promotions", s.handleListPromotions)
	})

	return r
}

// ---- auth ---------------------------------------------------------
//
// Verifies a Firebase ID token from `Authorization: Bearer <token>`, then
// resolves the internal user by email. Dev uses the Firebase Auth emulator
// (FIREBASE_AUTH_EMULATOR_HOST=localhost:9099); the SDK transparently uses
// it when that var is set.

type ctxKey int

const ctxUser ctxKey = 1

func (s *Server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(raw, prefix) {
			writeError(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		token := strings.TrimSpace(raw[len(prefix):])

		v, err := s.verify(r.Context(), token)
		if errors.Is(err, auth.ErrInvalidToken) {
			writeError(w, http.StatusUnauthorized, "invalid id token")
			return
		}
		if err != nil {
			log.Printf("verify: %v", err)
			writeError(w, http.StatusInternalServerError, "auth error")
			return
		}
		if v.Email == "" {
			writeError(w, http.StatusUnauthorized, "token has no email claim")
			return
		}

		u, err := s.store.UserByEmail(r.Context(), v.Email)
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusUnauthorized,
				"firebase user not provisioned in studio: "+v.Email)
			return
		}
		if err != nil {
			log.Printf("user lookup: %v", err)
			writeError(w, http.StatusInternalServerError, "auth error")
			return
		}
		ctx := context.WithValue(r.Context(), ctxUser, u)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func userFrom(r *http.Request) *store.User {
	u, _ := r.Context().Value(ctxUser).(*store.User)
	return u
}

// requireManager gates manager-only routes — callers must have role manager
// or owner. Layered after s.auth so the caller is already resolved.
// Used for: money mutators, configuration, taxonomy mutations, reports,
// dashboard (until revenue is redacted), audit log, staff CRUD, promotions.
func (s *Server) requireManager(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u := userFrom(r)
		if u == nil || (u.Role != "manager" && u.Role != "owner") {
			writeError(w, http.StatusForbidden, "manager access required")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// requireStaff gates routes that any non-student staff member needs to do
// their job — instructors included. Read-only schedule/roster views,
// attendance marking, check-in scan, and a few lookups. Same audit log
// applies; only the gate is looser.
func (s *Server) requireStaff(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u := userFrom(r)
		if u == nil || u.Role == "student" {
			writeError(w, http.StatusForbidden, "staff access required")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ---- handlers ------------------------------------------------------------

// meResponse extends the stored user with a derived `tier` so the client
// doesn't need to map roles → access tiers itself. Single source of truth
// for "what can this caller reach" lives in the same place as the route
// gates (s.requireStaff / s.requireManager).
type meResponse struct {
	*store.User
	Tier string `json:"tier"`
}

// tierForRole mirrors the gate policy in requireStaff / requireManager.
// Update this together with those middlewares.
func tierForRole(role string) string {
	switch role {
	case "manager", "owner":
		return "manager"
	case "instructor":
		return "staff"
	default:
		return "student"
	}
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	writeJSON(w, http.StatusOK, meResponse{User: u, Tier: tierForRole(u.Role)})
}

func (s *Server) handleStudioConfig(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	cfg, err := s.store.StudioConfig(r.Context(), u.StudioID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "studio not found")
		return
	}
	if err != nil {
		log.Printf("studio config: %v", err)
		writeError(w, http.StatusInternalServerError, "studio config error")
		return
	}
	writeJSON(w, http.StatusOK, cfg)
}

// GET /classes — accepts ?date=YYYY-MM-DD (single day) or ?from=&to= (range,
// to is exclusive). Returns scheduled classes with per-caller booking state.
func (s *Server) handleListClasses(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	q := r.URL.Query()
	dateStr := q.Get("date")
	fromStr := q.Get("from")
	toStr := q.Get("to")

	var (
		rows []store.ClassRow
		err  error
	)
	switch {
	case dateStr != "":
		day, perr := time.Parse("2006-01-02", dateStr)
		if perr != nil {
			writeError(w, http.StatusBadRequest, "date must be YYYY-MM-DD")
			return
		}
		rows, err = s.store.ClassesForDay(r.Context(), u.StudioID, u.ID, day)
	case fromStr != "" && toStr != "":
		from, errA := time.Parse("2006-01-02", fromStr)
		to, errB := time.Parse("2006-01-02", toStr)
		if errA != nil || errB != nil {
			writeError(w, http.StatusBadRequest, "from + to must be YYYY-MM-DD")
			return
		}
		fromUTC := time.Date(from.Year(), from.Month(), from.Day(), 0, 0, 0, 0, time.UTC)
		toUTC := time.Date(to.Year(), to.Month(), to.Day(), 0, 0, 0, 0, time.UTC)
		rows, err = s.store.ClassesInRange(r.Context(), u.StudioID, u.ID, fromUTC, toUTC)
	default:
		writeError(w, http.StatusBadRequest, "date or from+to query params required")
		return
	}

	if err != nil {
		log.Printf("list classes: %v", err)
		writeError(w, http.StatusInternalServerError, "list classes error")
		return
	}
	if rows == nil {
		rows = []store.ClassRow{}
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleListEnrollments(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListEnrollments(r.Context(), u.StudioID, u.ID)
	if err != nil {
		log.Printf("list enrollments: %v", err)
		writeError(w, http.StatusInternalServerError, "enrollments error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleEnrollmentDetail(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	det, err := s.store.GetEnrollmentDetail(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "enrollment not found")
		return
	}
	if err != nil {
		log.Printf("enrollment detail: %v", err)
		writeError(w, http.StatusInternalServerError, "enrollment error")
		return
	}
	writeJSON(w, http.StatusOK, det)
}

type joinEnrollmentReq struct {
	PaymentMethod string `json:"payment_method"`
}

func (s *Server) handleJoinEnrollment(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var req joinEnrollmentReq
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.PaymentMethod == "" {
		req.PaymentMethod = "dev_stub"
	}
	bookingID, err := s.store.JoinEnrollment(r.Context(), u.StudioID, u.ID, id, req.PaymentMethod)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "enrollment not found")
		return
	}
	if err != nil {
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{
		"enrollment_booking_id": bookingID,
	})
}

// GET /classes/{id}/eligible-entitlements
func (s *Server) handleEligibleEntitlements(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := chi.URLParam(r, "id")
	rows, err := s.store.EligibleEntitlements(r.Context(), u.StudioID, u.ID, classID)
	if err != nil {
		log.Printf("eligible entitlements: %v", err)
		writeError(w, http.StatusInternalServerError, "eligibility error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

// GET /bookings?scope=upcoming|past
func (s *Server) handleListBookings(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	scope := r.URL.Query().Get("scope")
	if scope == "" {
		scope = "upcoming"
	}
	var (
		rows []store.UpcomingBooking
		err  error
	)
	switch scope {
	case "upcoming":
		rows, err = s.store.UpcomingBookings(r.Context(), u.ID)
	case "past":
		rows, err = s.store.PastBookings(r.Context(), u.ID)
	default:
		writeError(w, http.StatusBadRequest, "scope must be upcoming or past")
		return
	}
	if err != nil {
		log.Printf("list bookings: %v", err)
		writeError(w, http.StatusInternalServerError, "list bookings error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

type createBookingReq struct {
	ClassID       string `json:"class_id"`
	EntitlementID string `json:"entitlement_id"`
	PlusOne       bool   `json:"plus_one"`
}

func (s *Server) handleCreateBooking(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req createBookingReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.ClassID == "" || req.EntitlementID == "" {
		writeError(w, http.StatusBadRequest, "class_id and entitlement_id are required")
		return
	}
	id, err := s.store.CreateBooking(r.Context(), u.StudioID, u.ID, req.ClassID, req.EntitlementID, req.PlusOne)
	var be *store.BookingError
	if errors.As(err, &be) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": be.Message, "code": be.Code})
		return
	}
	if err != nil {
		log.Printf("create booking: %v", err)
		writeError(w, http.StatusInternalServerError, "create booking error")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleCancelBooking(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.CancelBooking(r.Context(), u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "booking not found or already cancelled")
		return
	}
	if err != nil {
		log.Printf("cancel booking: %v", err)
		writeError(w, http.StatusInternalServerError, "cancel error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleClassDetail(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	out, err := s.store.GetClass(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class not found")
		return
	}
	if err != nil {
		log.Printf("class detail: %v", err)
		writeError(w, http.StatusInternalServerError, "class detail error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleProductDetail(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	out, err := s.store.GetProduct(r.Context(), u.StudioID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "product not found")
		return
	}
	if err != nil {
		log.Printf("product detail: %v", err)
		writeError(w, http.StatusInternalServerError, "product detail error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleListProducts(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListProducts(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("list products: %v", err)
		writeError(w, http.StatusInternalServerError, "list products error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

type createPurchaseReq struct {
	ProductID     string `json:"product_id"`
	PaymentMethod string `json:"payment_method"` // 'card' | 'cash' | 'dev_stub'
}

func (s *Server) handleListPurchases(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	scope := r.URL.Query().Get("scope")
	if scope == "" {
		scope = "mine"
	}
	if scope != "mine" {
		writeError(w, http.StatusBadRequest, "only scope=mine supported yet")
		return
	}
	rows, err := s.store.MyPurchases(r.Context(), u.ID)
	if err != nil {
		log.Printf("my purchases: %v", err)
		writeError(w, http.StatusInternalServerError, "purchases error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleMyEntitlements(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.MyEntitlements(r.Context(), u.ID)
	if err != nil {
		log.Printf("my entitlements: %v", err)
		writeError(w, http.StatusInternalServerError, "entitlements error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleMyAttendance(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.MyAttendance(r.Context(), u.ID)
	if err != nil {
		log.Printf("my attendance: %v", err)
		writeError(w, http.StatusInternalServerError, "attendance error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleCheckInCode(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.CheckInCode(r.Context(), u.ID)
	if err != nil {
		log.Printf("checkin code: %v", err)
		writeError(w, http.StatusInternalServerError, "checkin code error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleNotificationsFeed(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.NotificationsFeed(r.Context(), u.ID)
	if err != nil {
		log.Printf("notifications: %v", err)
		writeError(w, http.StatusInternalServerError, "notifications error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleMarkNotificationRead(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.MarkNotificationRead(r.Context(), u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "notification not found")
		return
	}
	if err != nil {
		log.Printf("mark read: %v", err)
		writeError(w, http.StatusInternalServerError, "mark read error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMarkAllNotificationsRead(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	n, err := s.store.MarkAllNotificationsRead(r.Context(), u.ID)
	if err != nil {
		log.Printf("mark all read: %v", err)
		writeError(w, http.StatusInternalServerError, "mark all read error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"marked": n})
}

func (s *Server) handleAdminDashboard(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.AdminDashboardFor(r.Context(), u.StudioID, u.ID)
	if err != nil {
		log.Printf("admin dashboard: %v", err)
		writeError(w, http.StatusInternalServerError, "dashboard error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminClasses(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	fromStr := r.URL.Query().Get("from")
	toStr := r.URL.Query().Get("to")
	if fromStr == "" || toStr == "" {
		writeError(w, http.StatusBadRequest, "from + to query params required (YYYY-MM-DD)")
		return
	}
	from, errA := time.Parse("2006-01-02", fromStr)
	to, errB := time.Parse("2006-01-02", toStr)
	if errA != nil || errB != nil {
		writeError(w, http.StatusBadRequest, "dates must be YYYY-MM-DD")
		return
	}
	rows, err := s.store.AdminClassesFor(r.Context(), u.StudioID, from, to)
	if err != nil {
		log.Printf("admin classes: %v", err)
		writeError(w, http.StatusInternalServerError, "admin classes error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminRoster(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := chi.URLParam(r, "id")
	out, err := s.store.RosterFor(r.Context(), u.StudioID, classID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class not found")
		return
	}
	if err != nil {
		log.Printf("roster: %v", err)
		writeError(w, http.StatusInternalServerError, "roster error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

type markAttendanceReq struct {
	Status string `json:"status"` // present | no_show | booked (undo)
	Via    string `json:"via"`    // manual | scan
}

func (s *Server) handleMarkAttendance(w http.ResponseWriter, r *http.Request) {
	bookingID := chi.URLParam(r, "id")
	var req markAttendanceReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	// Translate "present" → "attended" for the DB.
	status := req.Status
	if status == "present" {
		status = "attended"
	}
	via := req.Via
	if via == "" {
		via = "manual"
	}
	err := s.store.MarkAttendance(r.Context(), bookingID, status, via)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "booking not found")
		return
	}
	if err != nil {
		log.Printf("mark attendance: %v", err)
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handlePromoteWaitlist(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := chi.URLParam(r, "id")
	out, err := s.store.PromoteWaitlist(r.Context(), u.StudioID, classID)
	var be *store.BookingError
	if errors.As(err, &be) {
		writeJSON(w, http.StatusConflict, map[string]string{
			"error": be.Message, "code": be.Code,
		})
		return
	}
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class not found")
		return
	}
	if err != nil {
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleListThemes(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListThemes(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("list themes: %v", err)
		writeError(w, http.StatusInternalServerError, "list themes error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleCreateTheme(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.ThemeInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if strings.TrimSpace(in.Name) == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}
	id, err := s.store.CreateTheme(r.Context(), u.StudioID, in)
	if err != nil {
		log.Printf("create theme: %v", err)
		writeError(w, http.StatusInternalServerError, "create theme error")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleUpdateTheme(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	themeID := chi.URLParam(r, "id")
	var p store.ThemePatch
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateTheme(r.Context(), u.StudioID, themeID, p)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "theme not found")
		return
	}
	if err != nil {
		log.Printf("update theme: %v", err)
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleActivateTheme(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	themeID := chi.URLParam(r, "id")
	err := s.store.ActivateTheme(r.Context(), u.StudioID, themeID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "theme not found")
		return
	}
	if err != nil {
		log.Printf("activate theme: %v", err)
		writeError(w, http.StatusInternalServerError, "activate error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleUpdateStudioConfig(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var p store.StudioConfigPatch
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateStudioConfig(r.Context(), u.StudioID, p)
	if err != nil {
		log.Printf("update studio config: %v", err)
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminListProducts(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListAdminProducts(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin products: %v", err)
		writeError(w, http.StatusInternalServerError, "products error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminCreateProduct(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.AdminProductInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	id, err := s.store.CreateAdminProduct(r.Context(), u.StudioID, in)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleAdminUpdateProduct(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var in store.AdminProductInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateAdminProduct(r.Context(), u.StudioID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "product not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminArchiveProduct(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.ArchiveProduct(r.Context(), u.StudioID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "product not found")
		return
	}
	if err != nil {
		log.Printf("archive product: %v", err)
		writeError(w, http.StatusInternalServerError, "archive error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type studentsListResponse struct {
	Students []store.StudentSummary `json:"students"`
	Counts   struct {
		Total      int `json:"total"`
		ActivePass int `json:"active_pass"`
	} `json:"counts"`
}

func (s *Server) handleAdminListClassTemplates(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListClassTemplates(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("class templates: %v", err)
		writeError(w, http.StatusInternalServerError, "templates error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminCreateClassTemplate(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.ClassTemplateInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	out, err := s.store.CreateClassTemplateWithAudit(r.Context(), u.StudioID, u.ID, in)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, out)
}

func (s *Server) handleAdminUndoClassTemplate(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	out, err := s.store.UndoClassTemplateWithAudit(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "template not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminListInstructors(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListAdminInstructors(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin instructors: %v", err)
		writeError(w, http.StatusInternalServerError, "instructors error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminListRooms(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListAdminRooms(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin rooms: %v", err)
		writeError(w, http.StatusInternalServerError, "rooms error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminCreateClass(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.AdminClassInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	id, err := s.store.CreateAdminClassWithAudit(r.Context(), u.StudioID, u.ID, in)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleAdminUpdateClass(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var in store.AdminClassInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateAdminClass(r.Context(), u.StudioID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminCancelClass(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	out, err := s.store.CancelAdminClassWithAudit(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminCreateSeries(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.NewSeriesInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	out, err := s.store.CreateSeries(r.Context(), u.StudioID, u.ID, in)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, out)
}

func (s *Server) handleAdminListEnrollments(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListAdminEnrollments(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin enrollments: %v", err)
		writeError(w, http.StatusInternalServerError, "enrollments error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminUpdateEnrollment(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var in store.AdminEnrollmentInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateAdminEnrollment(r.Context(), u.StudioID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "enrollment not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminSeriesRoster(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	out, err := s.store.SeriesRosterFor(r.Context(), u.StudioID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "series not found")
		return
	}
	if err != nil {
		log.Printf("series roster: %v", err)
		writeError(w, http.StatusInternalServerError, "series roster error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminAudit(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	action := r.URL.Query().Get("action")
	rows, err := s.store.ListAudit(r.Context(), u.StudioID, action, 200)
	if err != nil {
		log.Printf("audit: %v", err)
		writeError(w, http.StatusInternalServerError, "audit error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminReports(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	out, err := s.store.AdminReportsFor(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin reports: %v", err)
		writeError(w, http.StatusInternalServerError, "reports error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminListStudents(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	q := r.URL.Query().Get("q")
	rows, counts, err := s.store.ListAdminStudents(r.Context(), u.StudioID, q)
	if err != nil {
		log.Printf("students: %v", err)
		writeError(w, http.StatusInternalServerError, "students error")
		return
	}
	out := studentsListResponse{Students: rows}
	if len(counts) >= 2 {
		out.Counts.Total = counts[0]
		out.Counts.ActivePass = counts[1]
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminGetStudent(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	out, err := s.store.GetAdminStudent(r.Context(), u.StudioID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "student not found")
		return
	}
	if err != nil {
		log.Printf("student detail: %v", err)
		writeError(w, http.StatusInternalServerError, "student error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminGrantPass(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	studentID := chi.URLParam(r, "id")
	var in store.GrantPassInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	out, err := s.store.GrantPass(r.Context(), u.StudioID, u.ID, studentID, in)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, out)
}

func (s *Server) handleAdminAdjustCredits(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	eid := chi.URLParam(r, "eid")
	var in store.AdjustCreditsInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.AdjustCredits(r.Context(), u.StudioID, u.ID, eid, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "entitlement not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminVoidEntitlement(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var in store.VoidInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	out, err := s.store.VoidEntitlement(r.Context(), u.StudioID, u.ID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "entitlement not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminListClassTypes(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListClassTypes(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("class types: %v", err)
		writeError(w, http.StatusInternalServerError, "class types error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminCreateClassType(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.ClassTypeInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	id, err := s.store.CreateClassType(r.Context(), u.StudioID, u.ID, in)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleAdminUpdateClassType(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var in store.ClassTypeInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateClassType(r.Context(), u.StudioID, u.ID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class type not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleJoinWaitlist(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	classID := chi.URLParam(r, "id")
	pos, err := s.store.JoinWaitlist(r.Context(), u.ID, classID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "class not found")
		return
	}
	if err != nil {
		// Could be unique conflict if already on the list.
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]int{"position": pos})
}

func (s *Server) handleCreatePurchase(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req createPurchaseReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.ProductID == "" {
		writeError(w, http.StatusBadRequest, "product_id is required")
		return
	}
	if req.PaymentMethod == "" {
		req.PaymentMethod = "dev_stub"
	}
	purchaseID, entitlementID, err := s.store.CreatePurchase(
		r.Context(), u.StudioID, u.ID, req.ProductID, req.PaymentMethod,
	)
	if err != nil {
		log.Printf("create purchase: %v", err)
		writeError(w, http.StatusInternalServerError, "create purchase error")
		return
	}
	ent, err := s.store.GetEntitlement(r.Context(), entitlementID)
	if err != nil {
		log.Printf("get entitlement: %v", err)
		writeError(w, http.StatusInternalServerError, "purchase succeeded but entitlement load failed")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"purchase_id": purchaseID,
		"entitlement": ent,
	})
}

type checkinScanReq struct {
	Token   string `json:"token"`
	ClassID string `json:"class_id"`
}

func (s *Server) handleAdminCheckinScan(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var req checkinScanReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	out, err := s.store.CheckinScan(r.Context(), u.StudioID, u.ID, req.Token, req.ClassID)
	var se *store.ScanError
	if errors.As(err, &se) {
		status := http.StatusConflict
		if se.Code == "invalid_token" || se.Code == "class_not_found" {
			status = http.StatusNotFound
		}
		writeJSON(w, status, map[string]string{"error": se.Message, "code": se.Code})
		return
	}
	if err != nil {
		log.Printf("checkin scan: %v", err)
		writeError(w, http.StatusInternalServerError, "scan error")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAdminListStaff(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListAdminStaff(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin staff: %v", err)
		writeError(w, http.StatusInternalServerError, "staff error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminCreateStaff(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.StaffInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	id, err := s.store.CreateStaff(r.Context(), u.StudioID, u.ID, in)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleAdminUpdateStaff(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var in store.StaffInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdateStaff(r.Context(), u.StudioID, u.ID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "staff member not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleListPromotions(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListActivePromotions(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("promotions: %v", err)
		writeError(w, http.StatusInternalServerError, "promotions error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminListPromotions(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	rows, err := s.store.ListAdminPromotions(r.Context(), u.StudioID)
	if err != nil {
		log.Printf("admin promotions: %v", err)
		writeError(w, http.StatusInternalServerError, "promotions error")
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) handleAdminCreatePromotion(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	var in store.PromotionInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	id, err := s.store.CreatePromotion(r.Context(), u.StudioID, u.ID, in)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": id})
}

func (s *Server) handleAdminUpdatePromotion(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	var in store.PromotionInput
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	err := s.store.UpdatePromotion(r.Context(), u.StudioID, u.ID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "promotion not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAdminArchivePromotion(w http.ResponseWriter, r *http.Request) {
	u := userFrom(r)
	id := chi.URLParam(r, "id")
	err := s.store.ArchivePromotion(r.Context(), u.StudioID, u.ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "promotion not found")
		return
	}
	if err != nil {
		log.Printf("archive promotion: %v", err)
		writeError(w, http.StatusInternalServerError, "archive error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- helpers -------------------------------------------------------------

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
