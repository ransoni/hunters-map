package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/ransoni/hunters-map/backend/internal/store"
)

var t0 = time.Date(2026, 10, 1, 6, 0, 0, 0, time.UTC)

type fixture struct {
	svc *Service
	mem *store.Memory
	now time.Time
}

func newFixture() *fixture {
	f := &fixture{mem: store.NewMemory(), now: t0}
	f.svc = New(f.mem, func() time.Time { return f.now })
	return f
}

var (
	alice = Identity{UID: "alice", Name: "Alice A", Email: "alice@example.com"}
	bob   = Identity{UID: "bob", Name: "", Email: "bob.b@example.com"}
	carol = Identity{UID: "carol", Name: "Carol"}
)

// must unwraps a (value, error) result; a failure panics, which fails the test.
func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

func noErr(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// groupWith creates a group owned by owner and joins the others via an invite.
func (f *fixture) groupWith(t *testing.T, owner Identity, others ...Identity) *store.Group {
	t.Helper()
	ctx := context.Background()
	g := must(f.svc.CreateGroup(ctx, owner, "Multian seurue"))
	inv := must(f.svc.CreateInvite(ctx, owner.UID, g.ID))
	for _, o := range others {
		f.now = f.now.Add(time.Minute) // distinct join times for ownership hand-over
		must(f.svc.JoinByInvite(ctx, o, inv.Code))
	}
	return g
}

func (f *fixture) location(t *testing.T, gid, uid string) *store.Location {
	t.Helper()
	var loc *store.Location
	_ = f.mem.RunTx(context.Background(), func(tx store.Tx) error {
		locs, _ := tx.ListLocations(gid)
		for _, l := range locs {
			if l.UserID == uid {
				loc = l
			}
		}
		return nil
	})
	return loc
}

func TestProfileDefaultsAndUpdate(t *testing.T) {
	f := newFixture()
	ctx := context.Background()

	if u := must(f.svc.Profile(ctx, alice)); u.DisplayName != "Alice A" {
		t.Errorf("name from token: got %q", u.DisplayName)
	}
	if u := must(f.svc.Profile(ctx, bob)); u.DisplayName != "bob.b" {
		t.Errorf("name from email: got %q", u.DisplayName)
	}
	if u := must(f.svc.Profile(ctx, Identity{UID: "x"})); u.DisplayName != "Metsästäjä" {
		t.Errorf("fallback name: got %q", u.DisplayName)
	}

	g := f.groupWith(t, alice, bob)
	must(f.svc.UpdateProfile(ctx, bob, "  Bob   the  Hunter "))
	d := must(f.svc.GetGroup(ctx, "alice", g.ID))
	if got := d.Members[1].DisplayName; got != "Bob the Hunter" {
		t.Errorf("member name not updated: %q", got)
	}
	if _, err := f.svc.UpdateProfile(ctx, bob, "   "); !errors.Is(err, ErrInvalid) {
		t.Errorf("empty name: got %v", err)
	}
}

func TestGroupMembershipAndVisibility(t *testing.T) {
	f := newFixture()
	ctx := context.Background()
	g := f.groupWith(t, alice, bob)

	d := must(f.svc.GetGroup(ctx, "bob", g.ID))
	if len(d.Members) != 2 || d.Members[0].Role != store.RoleOwner || d.Members[1].Role != store.RoleMember {
		t.Fatalf("unexpected members: %+v", d.Members)
	}
	// Non-members get not found, so group ids can't be probed.
	if _, err := f.svc.GetGroup(ctx, "carol", g.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("non-member: got %v", err)
	}
	if _, err := f.svc.CreateInvite(ctx, "carol", g.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("non-member invite: got %v", err)
	}
	groups := must(f.svc.ListGroups(ctx, "bob"))
	if len(groups) != 1 || groups[0].Role != store.RoleMember {
		t.Errorf("bob's groups: %+v", groups)
	}
	// Joining twice is harmless.
	inv := must(f.svc.CreateInvite(ctx, "bob", g.ID))
	must(f.svc.JoinByInvite(ctx, bob, inv.Code))
	if d := must(f.svc.GetGroup(ctx, "alice", g.ID)); len(d.Members) != 2 {
		t.Errorf("double join added a member")
	}
}

func TestInvites(t *testing.T) {
	f := newFixture()
	ctx := context.Background()
	g := must(f.svc.CreateGroup(ctx, alice, "Seurue"))
	inv := must(f.svc.CreateInvite(ctx, "alice", g.ID))
	if len(inv.Code) != 8 {
		t.Errorf("code %q", inv.Code)
	}
	// Codes are case-insensitive for typing.
	lower := []rune(inv.Code)
	for i, r := range lower {
		if r >= 'A' && r <= 'Z' {
			lower[i] = r + 32
		}
	}
	must(f.svc.JoinByInvite(ctx, bob, " "+string(lower)+" "))

	if _, err := f.svc.JoinByInvite(ctx, carol, "NOPE2345"); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown code: got %v", err)
	}
	f.now = f.now.Add(InviteTTL + time.Second)
	if _, err := f.svc.JoinByInvite(ctx, carol, inv.Code); !errors.Is(err, ErrNotFound) {
		t.Errorf("expired code: got %v", err)
	}
}

func TestOwnerLeavingHandsOverGroup(t *testing.T) {
	f := newFixture()
	ctx := context.Background()
	g := f.groupWith(t, alice, bob, carol)

	if err := f.svc.RemoveMember(ctx, "bob", g.ID, "carol"); !errors.Is(err, ErrForbidden) {
		t.Errorf("member removing another: got %v", err)
	}
	if err := f.svc.RemoveMember(ctx, "alice", g.ID, "alice"); err != nil {
		t.Fatal(err)
	}
	d := must(f.svc.GetGroup(ctx, "bob", g.ID))
	if d.Group.OwnerID != "bob" || d.Members[0].UserID != "bob" || d.Members[0].Role != store.RoleOwner {
		t.Errorf("bob (earliest joiner) should own the group: %+v", d)
	}
	if groups := must(f.svc.ListGroups(ctx, "alice")); len(groups) != 0 {
		t.Errorf("alice still lists the group")
	}
	// The new owner can remove members; the last one leaving deletes the group.
	noErr(t, f.svc.RemoveMember(ctx, "bob", g.ID, "carol"))
	noErr(t, f.svc.RemoveMember(ctx, "bob", g.ID, "bob"))
	if _, err := f.svc.GetGroup(ctx, "bob", g.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("group should be gone: %v", err)
	}
}

func TestDeleteGroup(t *testing.T) {
	f := newFixture()
	ctx := context.Background()
	g := f.groupWith(t, alice, bob)
	if err := f.svc.DeleteGroup(ctx, "bob", g.ID); !errors.Is(err, ErrForbidden) {
		t.Errorf("member delete: got %v", err)
	}
	must(f.svc.SetSharing(ctx, "bob", g.ID, ptr(t0.Add(time.Hour))))
	must(f.svc.UpdateLocation(ctx, "bob", LocationUpdate{Lat: 62.5, Lon: 25.0, Accuracy: 5}))
	noErr(t, f.svc.DeleteGroup(ctx, "alice", g.ID))
	if l := f.location(t, g.ID, "bob"); l != nil {
		t.Errorf("location left behind")
	}
	if groups := must(f.svc.ListGroups(ctx, "bob")); len(groups) != 0 {
		t.Errorf("bob still lists the deleted group")
	}
}

func TestSharingAndLocations(t *testing.T) {
	f := newFixture()
	ctx := context.Background()
	g1 := f.groupWith(t, alice, bob)
	g2 := f.groupWith(t, alice)
	upd := LocationUpdate{Lat: 62.52, Lon: 25.03, Accuracy: 8, Heading: ptr(90.0)}

	// Not sharing yet: nothing is stored.
	if gids := must(f.svc.UpdateLocation(ctx, "alice", upd)); len(gids) != 0 {
		t.Errorf("stored while not sharing: %v", gids)
	}

	// Sharing is capped to 24 h.
	until := must(f.svc.SetSharing(ctx, "alice", g1.ID, ptr(f.now.Add(72*time.Hour))))
	if !until.Equal(f.now.Add(MaxSharing)) {
		t.Errorf("cap: got %v", until)
	}
	gids := must(f.svc.UpdateLocation(ctx, "alice", upd))
	if len(gids) != 1 || gids[0] != g1.ID {
		t.Errorf("shared to %v, want only %s", gids, g1.ID)
	}
	loc := f.location(t, g1.ID, "alice")
	if loc == nil || loc.Lat != 62.52 || loc.DisplayName != "Alice A" || !loc.ExpireAt.Equal(until.Add(LocationTTL)) {
		t.Fatalf("location: %+v", loc)
	}
	if f.location(t, g2.ID, "alice") != nil {
		t.Errorf("location leaked to a group alice isn't sharing with")
	}

	// After sharing ends, updates are no longer stored.
	f.now = until.Add(time.Minute)
	if gids := must(f.svc.UpdateLocation(ctx, "alice", upd)); len(gids) != 0 {
		t.Errorf("stored after sharing ended: %v", gids)
	}

	// Stopping removes the position right away.
	must(f.svc.SetSharing(ctx, "alice", g1.ID, ptr(f.now.Add(time.Hour))))
	must(f.svc.UpdateLocation(ctx, "alice", upd))
	if stopped := must(f.svc.SetSharing(ctx, "alice", g1.ID, nil)); stopped != nil {
		t.Errorf("stop returned %v", stopped)
	}
	if f.location(t, g1.ID, "alice") != nil {
		t.Errorf("location kept after stopping")
	}

	// Leaving a group removes the position there.
	must(f.svc.SetSharing(ctx, "bob", g1.ID, ptr(f.now.Add(time.Hour))))
	must(f.svc.UpdateLocation(ctx, "bob", upd))
	noErr(t, f.svc.RemoveMember(ctx, "bob", g1.ID, "bob"))
	if f.location(t, g1.ID, "bob") != nil {
		t.Errorf("location kept after leaving")
	}

	if _, err := f.svc.SetSharing(ctx, "carol", g1.ID, ptr(f.now.Add(time.Hour))); !errors.Is(err, ErrNotFound) {
		t.Errorf("non-member sharing: got %v", err)
	}
}

func TestLocationValidation(t *testing.T) {
	f := newFixture()
	ctx := context.Background()
	bad := []LocationUpdate{
		{Lat: 91, Lon: 25},
		{Lat: 62, Lon: 181},
		{Lat: 62, Lon: 25, Accuracy: -1},
		{Lat: 62, Lon: 25, Heading: ptr(360.0)},
		{Lat: 62, Lon: 25, Speed: ptr(150.0)},
		{Lat: 62, Lon: 25, RecordedAt: t0.Add(-11 * time.Minute)},
		{Lat: 62, Lon: 25, RecordedAt: t0.Add(2 * time.Minute)},
	}
	for _, u := range bad {
		if _, err := f.svc.UpdateLocation(ctx, "alice", u); !errors.Is(err, ErrInvalid) {
			t.Errorf("%+v: got %v", u, err)
		}
	}
}

func TestLimits(t *testing.T) {
	f := newFixture()
	ctx := context.Background()
	for i := 0; i < MaxGroupsPerUser; i++ {
		must(f.svc.CreateGroup(ctx, alice, "G"))
	}
	if _, err := f.svc.CreateGroup(ctx, alice, "one too many"); !errors.Is(err, ErrLimit) {
		t.Errorf("group limit: got %v", err)
	}
	if _, err := f.svc.CreateGroup(ctx, bob, string(make([]rune, MaxNameLength+1))); !errors.Is(err, ErrInvalid) {
		t.Errorf("long name: got %v", err)
	}
}

func TestDeleteAccount(t *testing.T) {
	f := newFixture()
	ctx := context.Background()
	shared := f.groupWith(t, alice, bob)
	solo := f.groupWith(t, alice)

	noErr(t, f.svc.DeleteAccount(ctx, "alice"))

	if _, err := f.svc.GetGroup(ctx, "alice", solo.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("solo group should be deleted: %v", err)
	}
	d := must(f.svc.GetGroup(ctx, "bob", shared.ID))
	if d.Group.OwnerID != "bob" || len(d.Members) != 1 {
		t.Errorf("shared group should pass to bob: %+v", d)
	}
	var gone bool
	_ = f.mem.RunTx(ctx, func(tx store.Tx) error {
		_, err := tx.GetUser("alice")
		gone = errors.Is(err, store.ErrNotFound)
		return nil
	})
	if !gone {
		t.Errorf("profile not deleted")
	}
}

// The in-memory store enforces Firestore's reads-before-writes rule; make sure it does,
// since every test above relies on it to catch transactions that would fail in production.
func TestMemoryRejectsReadAfterWrite(t *testing.T) {
	m := store.NewMemory()
	err := m.RunTx(context.Background(), func(tx store.Tx) error {
		_ = tx.SetGroup(&store.Group{ID: "g"})
		_, err := tx.GetGroup("g")
		return err
	})
	if !errors.Is(err, store.ErrReadAfterWrite) {
		t.Fatalf("got %v", err)
	}
	// A failed transaction leaves nothing behind.
	_ = m.RunTx(context.Background(), func(tx store.Tx) error {
		if _, err := tx.GetGroup("g"); !errors.Is(err, store.ErrNotFound) {
			t.Errorf("write of failed transaction was applied")
		}
		return nil
	})
}

func ptr[T any](v T) *T { return &v }

func (f *fixture) track(gid, uid string) *store.Track {
	var tr *store.Track
	_ = f.mem.RunTx(context.Background(), func(tx store.Tx) error {
		tr, _ = tx.GetTrack(gid, uid)
		return nil
	})
	return tr
}

func TestTracks(t *testing.T) {
	f := newFixture()
	ctx := context.Background()
	g := f.groupWith(t, alice, bob)
	must(f.svc.SetSharing(ctx, "alice", g.ID, ptr(f.now.Add(MaxSharing))))

	// Walking north ~11 m per update: every update is a new point.
	for i := 0; i < 5; i++ {
		must(f.svc.UpdateLocation(ctx, "alice", LocationUpdate{Lat: 62.5 + float64(i)*0.0001, Lon: 25.0, Accuracy: 5}))
		f.now = f.now.Add(20 * time.Second)
	}
	if n := len(f.track(g.ID, "alice").Points); n != 5 {
		t.Fatalf("moving: %d points, want 5", n)
	}

	// Standing still: updates within a minute don't add points, but a minute later one is
	// added so the track shows the time spent there.
	still := LocationUpdate{Lat: 62.5004, Lon: 25.0, Accuracy: 5}
	for i := 0; i < 3; i++ { // 20 s after the last walking point, then +10 s, +10 s: < 1 min
		must(f.svc.UpdateLocation(ctx, "alice", still))
		f.now = f.now.Add(10 * time.Second)
	}
	if n := len(f.track(g.ID, "alice").Points); n != 5 {
		t.Errorf("standing still added points: %d", n)
	}
	f.now = f.now.Add(time.Minute)
	must(f.svc.UpdateLocation(ctx, "alice", still))
	if n := len(f.track(g.ID, "alice").Points); n != 6 {
		t.Errorf("minute-later point missing: %d", n)
	}

	// Points older than the window are dropped.
	f.now = f.now.Add(TrackWindow - time.Minute)
	must(f.svc.UpdateLocation(ctx, "alice", LocationUpdate{Lat: 62.51, Lon: 25.0, Accuracy: 5}))
	tr := f.track(g.ID, "alice")
	if len(tr.Points) != 2 || !tr.ExpireAt.After(f.now) {
		t.Errorf("after window: %d points (want the minute-later one and the new one), expireAt %v", len(tr.Points), tr.ExpireAt)
	}

	// Stopping sharing removes the track.
	must(f.svc.SetSharing(ctx, "alice", g.ID, nil))
	if f.track(g.ID, "alice") != nil {
		t.Errorf("track kept after stopping")
	}

	// So do leaving and deleting the group.
	must(f.svc.SetSharing(ctx, "bob", g.ID, ptr(f.now.Add(time.Hour))))
	must(f.svc.UpdateLocation(ctx, "bob", still))
	noErr(t, f.svc.RemoveMember(ctx, "bob", g.ID, "bob"))
	if f.track(g.ID, "bob") != nil {
		t.Errorf("track kept after leaving")
	}
	must(f.svc.SetSharing(ctx, "alice", g.ID, ptr(f.now.Add(time.Hour))))
	must(f.svc.UpdateLocation(ctx, "alice", still))
	noErr(t, f.svc.DeleteGroup(ctx, "alice", g.ID))
	if f.track(g.ID, "alice") != nil {
		t.Errorf("track kept after deleting the group")
	}
}
