package store

import (
	"context"
	"database/sql"
	"strconv"
	"strings"
)

// Whitelisted report builder.
//
// Managers compose ad-hoc tabular queries, but they NEVER send SQL. The server
// publishes a fixed registry of datasets → selectable columns + filterable
// fields, and RunBuilder compiles the chosen spec into a parameterized query
// with a forced `studio_id = ?` scope. Every identifier in the generated SQL
// comes from this registry (the `expr` fields below) — request strings only
// ever flow in as bound parameters. This is what keeps the feature safe from
// injection and cross-tenant reads.

// BuilderError marks a bad spec (unknown dataset/column/operator) so the
// handler can map it to 400 rather than 500.
type BuilderError struct{ Msg string }

func (e *BuilderError) Error() string { return e.Msg }

// BuilderColumn is a selectable output column. `expr` is the server-only SQL
// expression; it never leaves the process.
type BuilderColumn struct {
	Key   string `json:"key"`
	Label string `json:"label"`
	Type  string `json:"type"` // text | money | date | number
	expr  string
}

// BuilderFilter is a filterable field with the operators it permits.
type BuilderFilter struct {
	Key       string   `json:"key"`
	Label     string   `json:"label"`
	Type      string   `json:"type"` // text | money | date | number | enum
	Operators []string `json:"operators"`
	Options   []string `json:"options,omitempty"` // for enum
	expr      string
}

// BuilderDataset is one queryable "table" exposed to the builder.
type BuilderDataset struct {
	Key     string          `json:"key"`
	Label   string          `json:"label"`
	Columns []BuilderColumn `json:"columns"`
	Filters []BuilderFilter `json:"filters"`
	// Server-only query shape.
	from          string
	studioCol     string
	basePredicate string
}

func (d BuilderDataset) columnMap() map[string]BuilderColumn {
	m := make(map[string]BuilderColumn, len(d.Columns))
	for _, c := range d.Columns {
		m[c.Key] = c
	}
	return m
}

func (d BuilderDataset) filterMap() map[string]BuilderFilter {
	m := make(map[string]BuilderFilter, len(d.Filters))
	for _, f := range d.Filters {
		m[f.Key] = f
	}
	return m
}

// builderOps maps the operator tokens the client may send to their SQL form.
// "contains" is handled specially (LIKE %v%).
var builderOps = map[string]string{
	"eq":       "=",
	"ne":       "!=",
	"gt":       ">",
	"gte":      ">=",
	"lt":       "<",
	"lte":      "<=",
	"contains": "LIKE",
}

// builderDatasets is the entire surface the builder can touch. Adding a column
// here is a deliberate choice; anything not listed is unreachable. Secret /
// token columns (studio_stripe_credentials.*, users.firebase_uid,
// bookings.checkin_token) are intentionally absent.
var builderDatasets = map[string]BuilderDataset{
	"customers": {
		Key:           "customers",
		Label:         "Customers",
		from:          "users u",
		studioCol:     "u.studio_id",
		basePredicate: "u.role = 'student'",
		Columns: []BuilderColumn{
			{Key: "name", Label: "Name", Type: "text", expr: "u.full_name"},
			{Key: "email", Label: "Email", Type: "text", expr: "u.email"},
			{Key: "joined", Label: "Joined", Type: "date", expr: "u.created_at"},
		},
		Filters: []BuilderFilter{
			{Key: "name", Label: "Name", Type: "text", Operators: []string{"contains", "eq"}, expr: "u.full_name"},
			{Key: "email", Label: "Email", Type: "text", Operators: []string{"contains"}, expr: "u.email"},
			{Key: "joined", Label: "Joined", Type: "date", Operators: []string{"gte", "lte"}, expr: "u.created_at"},
		},
	},
	"purchases": {
		Key:       "purchases",
		Label:     "Revenue / purchases",
		from:      "purchases p JOIN users u ON u.id = p.user_id LEFT JOIN products pr ON pr.id = p.product_id",
		studioCol: "p.studio_id",
		Columns: []BuilderColumn{
			{Key: "customer", Label: "Customer", Type: "text", expr: "u.full_name"},
			{Key: "product", Label: "Product", Type: "text", expr: "pr.name"},
			{Key: "amount", Label: "Amount", Type: "money", expr: "p.amount_minor"},
			{Key: "list_price", Label: "List price", Type: "money", expr: "p.list_price_minor"},
			{Key: "discount", Label: "Discount", Type: "money", expr: "p.discount_minor"},
			{Key: "method", Label: "Method", Type: "text", expr: "p.payment_method"},
			{Key: "status", Label: "Status", Type: "text", expr: "p.status"},
			{Key: "created", Label: "Date", Type: "date", expr: "p.created_at"},
		},
		Filters: []BuilderFilter{
			{Key: "status", Label: "Status", Type: "enum", Operators: []string{"eq", "ne"},
				Options: []string{"completed", "pending", "refunded", "voided"}, expr: "p.status"},
			{Key: "method", Label: "Method", Type: "enum", Operators: []string{"eq", "ne"},
				Options: []string{"card", "card_present", "cash", "transfer", "comp", "dev_stub"}, expr: "p.payment_method"},
			{Key: "amount", Label: "Amount (minor)", Type: "money", Operators: []string{"eq", "gt", "gte", "lt", "lte"}, expr: "p.amount_minor"},
			{Key: "created", Label: "Date", Type: "date", Operators: []string{"gte", "lte"}, expr: "p.created_at"},
		},
	},
	"bookings": {
		Key:       "bookings",
		Label:     "Attendance / bookings",
		from:      "bookings b JOIN users u ON u.id = b.user_id JOIN classes c ON c.id = b.class_id LEFT JOIN class_types ct ON ct.id = c.class_type_id",
		studioCol: "b.studio_id",
		Columns: []BuilderColumn{
			{Key: "customer", Label: "Customer", Type: "text", expr: "u.full_name"},
			{Key: "class", Label: "Class", Type: "text", expr: "COALESCE(NULLIF(c.title,''), ct.name)"},
			{Key: "starts_at", Label: "Class time", Type: "date", expr: "c.starts_at"},
			{Key: "status", Label: "Status", Type: "text", expr: "b.status"},
			{Key: "plus_one", Label: "+1", Type: "number", expr: "b.is_plus_one"},
		},
		Filters: []BuilderFilter{
			{Key: "status", Label: "Status", Type: "enum", Operators: []string{"eq", "ne"},
				Options: []string{"booked", "cancelled", "attended", "no_show"}, expr: "b.status"},
			{Key: "starts_at", Label: "Class time", Type: "date", Operators: []string{"gte", "lte"}, expr: "c.starts_at"},
		},
	},
}

// BuilderSchema returns the datasets in a stable order for the picker UI.
func (s *Store) BuilderSchema() []BuilderDataset {
	order := []string{"customers", "purchases", "bookings"}
	out := make([]BuilderDataset, 0, len(order))
	for _, k := range order {
		out = append(out, builderDatasets[k])
	}
	return out
}

// BuilderSpec is the POST body for /admin/reports/builder/run.
type BuilderSpec struct {
	Dataset string              `json:"dataset"`
	Columns []string            `json:"columns"` // empty = all columns
	Filters []BuilderFilterCond `json:"filters"`
	Sort    string              `json:"sort"`     // column key
	SortDir string              `json:"sort_dir"` // asc | desc
	Limit   int                 `json:"limit"`
}

type BuilderFilterCond struct {
	Field    string `json:"field"`
	Operator string `json:"operator"`
	Value    string `json:"value"`
}

// BuilderResult is the tabular response: column metadata + stringified rows.
type BuilderResult struct {
	Columns []BuilderResultCol `json:"columns"`
	Rows    [][]string         `json:"rows"`
}

type BuilderResultCol struct {
	Key   string `json:"key"`
	Label string `json:"label"`
	Type  string `json:"type"`
}

// RunBuilder compiles and executes a spec against studioID. Every identifier is
// drawn from the registry; the only request-derived data that reaches SQL are
// bound parameters.
func (s *Store) RunBuilder(ctx context.Context, studioID string, spec BuilderSpec) (*BuilderResult, error) {
	ds, ok := builderDatasets[spec.Dataset]
	if !ok {
		return nil, &BuilderError{Msg: "unknown dataset"}
	}
	colByKey := ds.columnMap()

	// Resolve selected columns (default: all).
	keys := spec.Columns
	if len(keys) == 0 {
		for _, c := range ds.Columns {
			keys = append(keys, c.Key)
		}
	}
	selExprs := make([]string, 0, len(keys))
	outCols := make([]BuilderResultCol, 0, len(keys))
	for _, k := range keys {
		c, ok := colByKey[k]
		if !ok {
			return nil, &BuilderError{Msg: "unknown column: " + k}
		}
		selExprs = append(selExprs, c.expr)
		outCols = append(outCols, BuilderResultCol{Key: c.Key, Label: c.Label, Type: c.Type})
	}

	// WHERE: forced studio scope first, then the dataset's base predicate, then
	// each validated filter.
	args := []any{studioID}
	where := []string{ds.studioCol + " = ?"}
	if ds.basePredicate != "" {
		where = append(where, ds.basePredicate)
	}
	filterByKey := ds.filterMap()
	for _, cond := range spec.Filters {
		fdef, ok := filterByKey[cond.Field]
		if !ok {
			return nil, &BuilderError{Msg: "unknown filter: " + cond.Field}
		}
		if _, ok := builderOps[cond.Operator]; !ok || !sliceContains(fdef.Operators, cond.Operator) {
			return nil, &BuilderError{Msg: "operator not allowed: " + cond.Operator}
		}
		if cond.Operator == "contains" {
			where = append(where, fdef.expr+" LIKE ?")
			args = append(args, "%"+cond.Value+"%")
			continue
		}
		val := cond.Value
		// Date upper-bound: extend to end-of-day so "<= 30 Jun" includes that
		// day's timestamps.
		if fdef.Type == "date" && cond.Operator == "lte" && !strings.Contains(val, "T") {
			val += "T23:59:59Z"
		}
		where = append(where, fdef.expr+" "+builderOps[cond.Operator]+" ?")
		args = append(args, val)
	}

	query := "SELECT " + strings.Join(selExprs, ", ") +
		" FROM " + ds.from +
		" WHERE " + strings.Join(where, " AND ")

	if spec.Sort != "" {
		c, ok := colByKey[spec.Sort]
		if !ok {
			return nil, &BuilderError{Msg: "unknown sort column: " + spec.Sort}
		}
		dir := "ASC"
		if strings.EqualFold(spec.SortDir, "desc") {
			dir = "DESC"
		}
		query += " ORDER BY " + c.expr + " " + dir
	}

	limit := spec.Limit
	if limit <= 0 || limit > 1000 {
		limit = 200
	}
	query += " LIMIT " + strconv.Itoa(limit)

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	res := &BuilderResult{Columns: outCols, Rows: [][]string{}}
	n := len(outCols)
	holders := make([]sql.NullString, n)
	scan := make([]any, n)
	for i := range holders {
		scan[i] = &holders[i]
	}
	for rows.Next() {
		if err := rows.Scan(scan...); err != nil {
			return nil, err
		}
		row := make([]string, n)
		for i := range holders {
			if !holders[i].Valid {
				continue
			}
			if outCols[i].Type == "money" {
				row[i] = formatMinorString(holders[i].String)
			} else {
				row[i] = holders[i].String
			}
		}
		res.Rows = append(res.Rows, row)
	}
	return res, rows.Err()
}

func sliceContains(xs []string, v string) bool {
	for _, x := range xs {
		if x == v {
			return true
		}
	}
	return false
}

// formatMinorString renders an integer-minor cell ("2500" → "25.00"). Falls
// back to the raw value if it isn't an int.
func formatMinorString(s string) string {
	n, err := strconv.Atoi(s)
	if err != nil {
		return s
	}
	neg := n < 0
	if neg {
		n = -n
	}
	out := strconv.Itoa(n/100) + "." + leftPad2(n%100)
	if neg {
		return "-" + out
	}
	return out
}

func leftPad2(n int) string {
	s := strconv.Itoa(n)
	if len(s) < 2 {
		return "0" + s
	}
	return s
}
