package api

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/ransoni/hunters-map/backend/internal/auth"
	"github.com/ransoni/hunters-map/backend/internal/service"
	"github.com/ransoni/hunters-map/backend/internal/store"
)

func newServer(t *testing.T) *httptest.Server {
	t.Helper()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	s := New(service.New(store.NewMemory(), nil), auth.Dev{}, auth.Dev{}, log)
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	return ts
}

// call does one request as the given dev user ("" = no token) and decodes the JSON reply.
func call(t *testing.T, ts *httptest.Server, user, method, path string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, ts.URL+path, rd)
	if user != "" {
		req.Header.Set("Authorization", "Bearer dev:"+user+":"+user)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func TestRequiresAuth(t *testing.T) {
	ts := newServer(t)
	if code, _ := call(t, ts, "", "GET", "/healthz", nil); code != http.StatusOK {
		t.Errorf("healthz: %d", code)
	}
	if code, body := call(t, ts, "", "GET", "/v1/me", nil); code != http.StatusUnauthorized {
		t.Errorf("no token: %d %v", code, body)
	}
	req, _ := http.NewRequest("GET", ts.URL+"/v1/me", nil)
	req.Header.Set("Authorization", "Bearer not-a-dev-token")
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("bad token: %d", resp.StatusCode)
	}
}

// The whole sharing flow over HTTP: profile, group, invite, join, share, locate, leave.
func TestSharingFlow(t *testing.T) {
	ts := newServer(t)

	code, me := call(t, ts, "alice", "GET", "/v1/me", nil)
	if code != 200 || me["displayName"] != "alice" {
		t.Fatalf("me: %d %v", code, me)
	}
	code, me = call(t, ts, "alice", "PUT", "/v1/me", map[string]string{"displayName": "Alice"})
	if code != 200 || me["displayName"] != "Alice" {
		t.Fatalf("put me: %d %v", code, me)
	}

	code, g := call(t, ts, "alice", "POST", "/v1/groups", map[string]string{"name": "Multian seurue"})
	if code != 201 || g["role"] != "owner" {
		t.Fatalf("create group: %d %v", code, g)
	}
	gid := g["id"].(string)

	code, inv := call(t, ts, "alice", "POST", "/v1/groups/"+gid+"/invites", nil)
	if code != 201 {
		t.Fatalf("invite: %d %v", code, inv)
	}
	if code, _ := call(t, ts, "bob", "GET", "/v1/groups/"+gid, nil); code != 404 {
		t.Errorf("non-member sees group: %d", code)
	}
	if code, body := call(t, ts, "bob", "POST", "/v1/invites/"+inv["code"].(string)+"/join", nil); code != 200 {
		t.Fatalf("join: %d %v", code, body)
	}

	until := time.Now().Add(2 * time.Hour).UTC().Format(time.RFC3339)
	code, sh := call(t, ts, "bob", "PUT", "/v1/groups/"+gid+"/sharing", map[string]any{"until": until})
	if code != 200 || sh["sharing"] != true {
		t.Fatalf("share: %d %v", code, sh)
	}
	code, loc := call(t, ts, "bob", "POST", "/v1/locations", map[string]any{"lat": 62.52, "lon": 25.03, "accuracy": 6})
	if code != 200 || len(loc["groups"].([]any)) != 1 {
		t.Fatalf("location: %d %v", code, loc)
	}

	code, detail := call(t, ts, "alice", "GET", "/v1/groups/"+gid, nil)
	members, _ := detail["members"].([]any)
	if code != 200 || len(members) != 2 {
		t.Fatalf("group detail: %d %v", code, detail)
	}
	if bob := members[1].(map[string]any); bob["sharingUntil"] == nil {
		t.Errorf("bob should show as sharing: %v", bob)
	}

	code, list := call(t, ts, "bob", "GET", "/v1/groups", nil)
	if groups := list["groups"].([]any); code != 200 || len(groups) != 1 {
		t.Fatalf("list: %d %v", code, list)
	}

	if code, _ := call(t, ts, "bob", "DELETE", "/v1/groups/"+gid, nil); code != 403 {
		t.Errorf("member deleting group: %d", code)
	}
	if code, _ := call(t, ts, "bob", "DELETE", "/v1/groups/"+gid+"/members/bob", nil); code != 204 {
		t.Errorf("leave: %d", code)
	}
	if code, _ := call(t, ts, "alice", "DELETE", "/v1/me", nil); code != 204 {
		t.Errorf("delete account: %d", code)
	}
}

func TestBadRequests(t *testing.T) {
	ts := newServer(t)
	cases := []struct {
		method, path string
		body         any
		want         int
	}{
		{"POST", "/v1/groups", map[string]string{"name": ""}, 400},
		{"POST", "/v1/groups", map[string]string{"nimi": "x"}, 400}, // unknown field
		{"POST", "/v1/locations", map[string]any{"lat": 62.5}, 400},
		{"POST", "/v1/locations", map[string]any{"lat": 100, "lon": 25}, 400},
		{"POST", "/v1/invites/SHORT/join", nil, 400},
		{"POST", "/v1/invites/ABCDEFGH/join", nil, 404},
		{"GET", "/v1/groups/nope", nil, 404},
	}
	for _, c := range cases {
		if code, body := call(t, ts, "alice", c.method, c.path, c.body); code != c.want {
			t.Errorf("%s %s: got %d %v, want %d", c.method, c.path, code, body, c.want)
		}
	}
}
