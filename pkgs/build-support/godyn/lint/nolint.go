package main

import (
	"go/ast"
	"go/token"
	"regexp"
	"strings"

	"golang.org/x/tools/go/analysis"
)

// suppressNolint makes every analyzer drop diagnostics that a golangci-lint style
// //nolint directive covers, and diagnostics in generated files. It rewrites Run in
// place rather than wrapping a copy: Requires/ResultOf and fact registration key on
// the analyzer's identity, so a copy would run twice and register its facts twice.
func suppressNolint(analyzers []*analysis.Analyzer) {
	for _, a := range analyzers {
		run, name := a.Run, a.Name
		a.Run = func(pass *analysis.Pass) (any, error) {
			idx := indexNolint(pass.Fset, pass.Files)
			filtered := *pass
			filtered.Report = func(d analysis.Diagnostic) {
				if !idx.suppresses(name, d.Pos) {
					pass.Report(d)
				}
			}
			return run(&filtered)
		}
	}
}

// nolintRange is the lines one directive covers; names == nil means every linter.
type nolintRange struct {
	from, to int
	names    map[string]bool
}

type nolintIndex struct {
	fset      *token.FileSet
	generated map[string]bool
	ranges    map[string][]nolintRange
}

// indexNolint records, per file, the lines each //nolint covers. golangci-lint's
// rules: a directive after code covers its own line; a directive on its own line
// covers the whole node that starts on the next line (a func, a statement, a field).
func indexNolint(fset *token.FileSet, files []*ast.File) *nolintIndex {
	idx := &nolintIndex{fset: fset, generated: map[string]bool{}, ranges: map[string][]nolintRange{}}
	for _, f := range files {
		filename := fset.Position(f.Pos()).Filename
		if ast.IsGenerated(f) {
			idx.generated[filename] = true
			continue
		}
		outermostAt := outermostNodeByLine(fset, f)
		for _, cg := range f.Comments {
			for _, c := range cg.List {
				names, ok := parseNolint(c.Text)
				if !ok {
					continue
				}
				pos := fset.Position(c.Slash)
				r := nolintRange{from: pos.Line, to: pos.Line, names: names}
				onLine, codeBefore := outermostAt[pos.Line]
				codeBefore = codeBefore && fset.Position(onLine.Pos()).Column < pos.Column
				if next, ok := outermostAt[pos.Line+1]; ok && !codeBefore {
					r.to = fset.Position(next.End()).Line
				}
				idx.ranges[filename] = append(idx.ranges[filename], r)
			}
		}
	}
	return idx
}

// outermostNodeByLine maps each line to the first (outermost, pre-order) syntax
// node starting on it, ignoring comments.
func outermostNodeByLine(fset *token.FileSet, f *ast.File) map[int]ast.Node {
	byLine := map[int]ast.Node{}
	ast.Inspect(f, func(n ast.Node) bool {
		switch n.(type) {
		case nil:
			return false
		case *ast.File, *ast.CommentGroup, *ast.Comment:
			return true
		}
		if line := fset.Position(n.Pos()).Line; byLine[line] == nil {
			byLine[line] = n
		}
		return true
	})
	return byLine
}

func (idx *nolintIndex) suppresses(analyzer string, pos token.Pos) bool {
	p := idx.fset.Position(pos)
	if idx.generated[p.Filename] {
		return true
	}
	for _, r := range idx.ranges[p.Filename] {
		if p.Line >= r.from && p.Line <= r.to && r.covers(analyzer) {
			return true
		}
	}
	return false
}

func (r nolintRange) covers(analyzer string) bool {
	if r.names == nil {
		return true
	}
	for _, n := range linterNames(analyzer) {
		if r.names[n] {
			return true
		}
	}
	return false
}

// parseNolint reads "//nolint" (every linter) or "//nolint:a,b" (named ones); a
// trailing " // reason" is allowed. ok is false for any other comment.
func parseNolint(text string) (names map[string]bool, ok bool) {
	s := strings.TrimSpace(strings.TrimPrefix(text, "//"))
	rest, found := strings.CutPrefix(s, "nolint")
	if !found {
		return nil, false
	}
	if i := strings.IndexAny(rest, " \t"); i >= 0 {
		rest = rest[:i]
	}
	if rest == "" {
		return nil, true
	}
	list, found := strings.CutPrefix(rest, ":")
	if !found {
		return nil, false
	}
	names = map[string]bool{}
	for _, n := range strings.Split(list, ",") {
		if n = strings.ToLower(strings.TrimSpace(n)); n != "" {
			names[n] = true
		}
	}
	if names["all"] {
		return nil, true
	}
	return names, true
}

var staticcheckCode = regexp.MustCompile(`^(sa|s|st|qf)\d+$`)

// linterNames is every name a //nolint may use for an analyzer: the analyzer's own
// name (a vet pass like "printf", or a check code like "SA1019"), plus the
// golangci-lint linter it runs under — "govet" for vet passes; "staticcheck" for
// every staticcheck code, and the golangci-lint v1 "gosimple"/"stylecheck" names.
func linterNames(analyzer string) []string {
	a := strings.ToLower(analyzer)
	m := staticcheckCode.FindStringSubmatch(a)
	if m == nil {
		return []string{a, "govet"}
	}
	switch m[1] {
	case "s":
		return []string{a, "staticcheck", "gosimple"}
	case "st":
		return []string{a, "staticcheck", "stylecheck"}
	default:
		return []string{a, "staticcheck"}
	}
}
