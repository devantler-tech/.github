package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode"
)

// unknown retains incomplete expression evidence instead of treating it as false.
type unknown struct{ truthFact int }

// builtinToken marks the approved native credential without inventing its value.
type builtinToken struct{}

var uncertain any = unknown{}

type context map[string]any

// known distinguishes measured values, including false and empty, from unresolved ones.
func known(v any) bool {
	switch x := v.(type) {
	case unknown, builtinToken:
		return false
	case object:
		for _, v := range x {
			if !known(v) {
				return false
			}
		}
	case map[string]any:
		for _, v := range x {
			if !known(v) {
				return false
			}
		}
	case []any:
		for _, v := range x {
			if !known(v) {
				return false
			}
		}
	}
	return true
}

// truth applies Actions truthiness only to values whose identity is known.
func truth(v any) any {
	if u, ok := v.(unknown); ok {
		if u.truthFact == 1 {
			return false
		}
		if u.truthFact == 2 {
			return true
		}
		return uncertain
	}
	if !known(v) {
		return uncertain
	}
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case string:
		return x != ""
	case int:
		return x != 0
	case float64:
		return x != 0
	}
	return true
}

// combine preserves short-circuit proofs even when the other operand is unresolved.
func combine(a, b any, or bool) any {
	a, b = truth(a), truth(b)
	if or {
		if a == true || b == true {
			return unknown{truthFact: 2}
		}
		if a == false && b == false {
			return unknown{truthFact: 1}
		}
	} else {
		if a == false || b == false {
			return unknown{truthFact: 1}
		}
		if a == true && b == true {
			return unknown{truthFact: 2}
		}
	}
	return uncertain
}

type token struct {
	text    string
	literal bool
}
type parser struct {
	tokens []token
	at     int
	ctx    context
	bad    bool
}

// lex accepts the bounded boolean/value expression syntax used for admission proofs.
func lex(s string) ([]token, error) {
	var out []token
	for i := 0; i < len(s); {
		if unicode.IsSpace(rune(s[i])) {
			i++
			continue
		}
		if s[i] == '\'' || s[i] == '"' {
			q := s[i]
			i++
			var b strings.Builder
			closed := false
			for i < len(s) {
				if s[i] == q {
					if i+1 < len(s) && s[i+1] == q {
						b.WriteByte(q)
						i += 2
						continue
					}
					i++
					closed = true
					break
				}
				b.WriteByte(s[i])
				i++
			}
			if !closed {
				return nil, fmt.Errorf("unterminated string")
			}
			out = append(out, token{b.String(), true})
			continue
		}
		if i+1 < len(s) {
			op := s[i : i+2]
			if op == "&&" || op == "||" || op == "==" || op == "!=" {
				out = append(out, token{op, false})
				i += 2
				continue
			}
		}
		if strings.ContainsRune("!(),[]", rune(s[i])) {
			out = append(out, token{s[i : i+1], false})
			i++
			continue
		}
		start := i
		for i < len(s) && (unicode.IsLetter(rune(s[i])) || unicode.IsDigit(rune(s[i])) || strings.ContainsRune("._-*", rune(s[i]))) {
			i++
		}
		if start == i {
			return nil, fmt.Errorf("unsupported expression character")
		}
		out = append(out, token{s[start:i], false})
	}
	return out, nil
}

// evaluate never grants a skipped result for unsupported or partial expression syntax.
func evaluate(v any, c context) any {
	s, ok := v.(string)
	if !ok {
		return v
	}
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, "$"+"{{") && strings.HasSuffix(s, "}}") {
		s = strings.TrimSpace(s[3 : len(s)-2])
	}
	tt, err := lex(s)
	if err != nil || len(tt) == 0 {
		return uncertain
	}
	p := parser{tokens: tt, ctx: c}
	result := p.or()
	if p.bad || p.at != len(tt) {
		return uncertain
	}
	return result
}

// take consumes a syntax token without changing literal-value tokens.
func (p *parser) take(s string) bool {
	if p.at < len(p.tokens) && !p.tokens[p.at].literal && p.tokens[p.at].text == s {
		p.at++
		return true
	}
	return false
}

// or evaluates the lowest-precedence boolean operation.
func (p *parser) or() any {
	a := p.and()
	for p.take("||") {
		b := p.and()
		if truth(a) == true {
			continue
		}
		if truth(a) == false {
			a = b
		} else {
			a = combine(a, b, true)
		}
	}
	return a
}

// and preserves the selected operand for Actions-style value fallbacks.
func (p *parser) and() any {
	a := p.equal()
	for p.take("&&") {
		b := p.equal()
		if truth(a) == false {
			continue
		}
		if truth(a) == true {
			a = b
		} else {
			a = combine(a, b, false)
		}
	}
	return a
}

// equal compares known scalar values; unknown operands never prove equality.
func (p *parser) equal() any {
	a := p.unary()
	for {
		neg := false
		if p.take("==") {
		} else if p.take("!=") {
			neg = true
		} else {
			break
		}
		b := p.unary()
		if !known(a) || !known(b) {
			a = uncertain
			continue
		}
		same := false
		if !scalar(a) || !scalar(b) {
			a = uncertain
			continue
		}
		if fmt.Sprintf("%T", a) != fmt.Sprintf("%T", b) {
			a = uncertain
			continue
		}
		switch v := a.(type) {
		case string:
			if v != b.(string) && (!ascii(v) || !ascii(b.(string))) {
				a = uncertain
				continue
			}
			same = strings.EqualFold(v, b.(string))
		case float64:
			same = v == b.(float64)
		case int:
			same = v == b.(int)
		case bool:
			same = v == b.(bool)
		case nil:
			same = true
		}
		a = same != neg
	}
	return a
}

// unary negates only a measured truth value.
func (p *parser) unary() any {
	if p.take("!") {
		v := truth(p.unary())
		if !known(v) {
			return uncertain
		}
		return v != true
	}
	return p.value()
}

// value resolves literals, context paths and supported pure functions.
func (p *parser) value() any {
	if p.take("(") {
		v := p.or()
		if !p.take(")") {
			p.bad = true
		}
		return v
	}
	if p.at >= len(p.tokens) {
		p.bad = true
		return uncertain
	}
	t := p.tokens[p.at]
	p.at++
	if t.literal {
		return t.text
	}
	if p.take("(") {
		var args []any
		if !p.take(")") {
			for {
				args = append(args, p.or())
				if p.take(")") {
					break
				}
				if !p.take(",") {
					p.bad = true
					break
				}
			}
		}
		return call(t.text, args)
	}
	key := t.text
	if p.take("[") {
		if p.at >= len(p.tokens) || !p.tokens[p.at].literal {
			p.bad = true
			return uncertain
		}
		key += "." + p.tokens[p.at].text
		p.at++
		if !p.take("]") {
			p.bad = true
		}
	}
	switch strings.ToLower(key) {
	case "true":
		return true
	case "false":
		return false
	case "null":
		return nil
	}
	var numeric any
	if json.Unmarshal([]byte(key), &numeric) == nil {
		if f, ok := numeric.(float64); ok {
			return f
		}
	}
	if strings.HasPrefix(key, "__") {
		return uncertain
	}
	if v, ok := p.ctx[strings.ToLower(key)]; ok {
		return v
	}
	return uncertain
}

// call evaluates pure functions needed for proofs; runtime status remains unresolved.
func call(name string, args []any) any {
	name = strings.ToLower(name)
	if name == "always" && len(args) == 0 {
		return true
	}
	for _, a := range args {
		if !known(a) {
			return uncertain
		}
	}
	switch name {
	case "startswith":
		if len(args) == 2 {
			a, ok := args[0].(string)
			b, ok2 := args[1].(string)
			if ok && ok2 {
				if !ascii(a) || !ascii(b) {
					return uncertain
				}
				return strings.HasPrefix(strings.ToLower(a), strings.ToLower(b))
			}
		}
	case "contains":
		if len(args) == 2 {
			needle, ok := stringValue(args[1])
			if !ok {
				return uncertain
			}
			if items, ok := args[0].([]any); ok {
				for _, item := range items {
					s, ok := stringValue(item)
					if !ok {
						return uncertain
					}
					if !ascii(s) || !ascii(needle) {
						return uncertain
					}
					if strings.EqualFold(s, needle) {
						return true
					}
				}
				return false
			}
			haystack, ok := stringValue(args[0])
			if !ok {
				return uncertain
			}
			if !ascii(haystack) || !ascii(needle) {
				return uncertain
			}
			return strings.Contains(strings.ToLower(haystack), strings.ToLower(needle))
		}
	case "format":
		if len(args) > 0 {
			s, ok := args[0].(string)
			if ok {
				if strings.Contains(s, "{{") || strings.Contains(s, "}}") {
					return uncertain
				}
				for i, v := range args[1:] {
					replacement, valid := stringValue(v)
					if !valid {
						return uncertain
					}
					if strings.ContainsAny(replacement, "{}") {
						return uncertain
					}
					s = strings.ReplaceAll(s, fmt.Sprintf("{%d}", i), replacement)
				}
				if strings.ContainsAny(s, "{}") {
					return uncertain
				}
				return s
			}
		}
	case "tojson":
		if len(args) == 1 {
			switch v := args[0].(type) {
			case string:
				for _, r := range v {
					if r < 0x20 || r > 0x7e || r == '<' || r == '>' || r == '&' {
						return uncertain
					}
				}
			case float64:
				return uncertain
			case int:
				if v != 0 {
					return uncertain
				}
			case object:
				if len(v) != 0 {
					return uncertain
				}
			case map[string]any:
				if len(v) != 0 {
					return uncertain
				}
			case []any:
				if len(v) != 0 {
					return uncertain
				}
			}
			b, e := json.Marshal(args[0])
			if e == nil {
				return string(b)
			}
		}
	case "fromjson":
		if len(args) == 1 {
			s, ok := args[0].(string)
			if ok {
				var v any
				if json.Unmarshal([]byte(s), &v) == nil {
					return v
				}
			}
		}
	}
	return uncertain
}

// scalar excludes runtime object identity from value-comparison proofs.
func scalar(v any) bool {
	switch v.(type) {
	case nil, bool, string, int, float64:
		return true
	}
	return false
}

// stringValue uses Actions scalar string conversion and refuses compound values.
func stringValue(v any) (string, bool) {
	switch x := v.(type) {
	case nil:
		return "", true
	case string:
		return x, true
	case bool:
		if x {
			return "true", true
		}
		return "false", true
	}
	return "", false
}

// ascii excludes unmeasured cross-runtime Unicode case folding from skip proofs.
func ascii(s string) bool {
	for _, r := range s {
		if r > 127 {
			return false
		}
	}
	return true
}
