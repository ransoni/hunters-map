// Command simhunter adds a simulated hunter to a group and walks it around, for testing the
// app's live positions without a second phone. It writes straight to Firestore (with your
// Application Default Credentials), like the API would, and removes the hunter on Ctrl-C.
//
//	go run ./cmd/simhunter -group <groupId> [-lat 62.5277 -lon 25.0317] [-name Testimetsästäjä]
//
// It alternates walking (-walk) and standing still (-pause), so trails, direction arrows and
// "paikallaan X min" labels can all be seen.
//
// The group id is shown by `GET /v1/groups` or in Firestore under groups/.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"math"
	"math/rand/v2"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/ransoni/hunters-map/backend/internal/service"
	"github.com/ransoni/hunters-map/backend/internal/store"
)

const metresPerDegree = 111_320.0

func main() {
	project := flag.String("project", envOr("GOOGLE_CLOUD_PROJECT", "ai-project-479422"), "GCP project")
	database := flag.String("database", "hunters-map", "Firestore database")
	group := flag.String("group", "", "group id to join (required)")
	name := flag.String("name", "Testimetsästäjä", "display name")
	lat := flag.Float64("lat", 62.5277, "centre of the walk, latitude")
	lon := flag.Float64("lon", 25.0317, "centre of the walk, longitude")
	radius := flag.Float64("radius", 500, "stay within this many metres of the centre")
	speed := flag.Float64("speed", 1.4, "walking speed, m/s (try 5 to see movement faster)")
	interval := flag.Duration("interval", 5*time.Second, "how often the position is updated")
	duration := flag.Duration("duration", 2*time.Hour, "sharing duration")
	walkFor := flag.Duration("walk", 3*time.Minute, "walk this long, then stand still for -pause")
	pauseFor := flag.Duration("pause", 7*time.Minute, "stand still this long (0 = never stop)")
	flag.Parse()
	if *group == "" {
		flag.Usage()
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	client, err := firestore.NewClientWithDatabase(ctx, *project, *database)
	if err != nil {
		log.Fatal(err)
	}
	defer client.Close()

	groupRef := client.Collection("groups").Doc(*group)
	if _, err := groupRef.Get(ctx); err != nil {
		log.Fatalf("group %s: %v", *group, err)
	}
	uid := "sim-" + strings.ToLower(strings.Join(strings.Fields(*name), "-"))
	memberRef := groupRef.Collection("members").Doc(uid)
	locationRef := groupRef.Collection("locations").Doc(uid)
	trackRef := groupRef.Collection("tracks").Doc(uid)
	track := &store.Track{UserID: uid}

	until := time.Now().UTC().Add(*duration)
	member := &store.Member{DisplayName: *name, Role: store.RoleMember, JoinedAt: time.Now().UTC(), SharingUntil: &until}
	if _, err := memberRef.Set(ctx, member); err != nil {
		log.Fatal(err)
	}
	log.Printf("%s joined group %s, walking around %.5f,%.5f (Ctrl-C stops and removes it)", *name, *group, *lat, *lon)

	defer func() {
		// The signal context is cancelled by now; clean up with a fresh one.
		cleanup, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_, err1 := locationRef.Delete(cleanup)
		_, err2 := trackRef.Delete(cleanup)
		_, err3 := memberRef.Delete(cleanup)
		if err1 != nil || err2 != nil || err3 != nil {
			log.Printf("cleanup failed (delete groups/%s/{members,locations,tracks}/%s by hand): %v %v %v", *group, uid, err1, err2, err3)
			return
		}
		log.Printf("%s removed", *name)
	}()

	w := walker{x: 0, y: 0, heading: rand.Float64() * 2 * math.Pi, radius: *radius}
	ticker := time.NewTicker(*interval)
	defer ticker.Stop()
	started := time.Now()
	for {
		la, lo := w.position(*lat, *lon)
		now := time.Now().UTC()
		walking := isWalking(time.Since(started), *walkFor, *pauseFor)
		loc := &store.Location{
			DisplayName: *name, Lat: la, Lon: lo, Accuracy: 5 + rand.Float64()*5,
			RecordedAt: now, UpdatedAt: now, SharingUntil: until, ExpireAt: until.Add(time.Hour),
		}
		if walking { // like the app: a direction only while moving
			heading := math.Mod(90-w.heading*180/math.Pi+360, 360) // compass degrees
			loc.Heading, loc.Speed = &heading, speed
		}
		service.AppendTrackPoint(track, store.TrackPoint{Lat: la, Lon: lo, T: now}, now)
		track.UpdatedAt, track.ExpireAt = now, loc.ExpireAt
		_, err := locationRef.Set(ctx, loc)
		if err == nil {
			_, err = trackRef.Set(ctx, track)
		}
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("update failed: %v", err)
		} else {
			state := "kävelee"
			if !walking {
				state = "paikallaan"
			}
			fmt.Printf("\r%s  %.5f, %.5f  %-10s  %d pistettä  ", now.Local().Format("15:04:05"), la, lo, state, len(track.Points))
		}

		select {
		case <-ctx.Done():
			fmt.Println()
			return
		case <-ticker.C:
			if walking {
				w.step(*speed * interval.Seconds())
			}
		}
	}
}

// isWalking: walk for `walk`, stand still for `pause`, repeat.
func isWalking(elapsed, walk, pause time.Duration) bool {
	if pause <= 0 {
		return true
	}
	return elapsed%(walk+pause) < walk
}

// walker wanders like a person: small random turns, steering back towards the centre when
// it gets near the edge of the allowed area. x/y are metres east/north of the centre.
type walker struct {
	x, y, heading, radius float64
}

func (w *walker) step(metres float64) {
	w.heading += (rand.Float64() - 0.5) * 0.6 // up to ±17°
	if dist := math.Hypot(w.x, w.y); dist > w.radius*0.8 {
		home := math.Atan2(-w.y, -w.x)
		turn := math.Remainder(home-w.heading, 2*math.Pi)
		w.heading += turn * 0.3
	}
	w.x += metres * math.Cos(w.heading)
	w.y += metres * math.Sin(w.heading)
}

func (w *walker) position(lat, lon float64) (float64, float64) {
	return lat + w.y/metresPerDegree,
		lon + w.x/(metresPerDegree*math.Cos(lat*math.Pi/180))
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
