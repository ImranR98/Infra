package main

import (
	"log"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/oschwald/maxminddb-golang"
)

var (
	dbMu   sync.RWMutex
	db     *maxminddb.Reader
	dbPath = "/data/GeoLite2-Country.mmdb"
)

type countryRecord struct {
	Country struct {
		ISOCode string `maxminddb:"iso_code"`
	} `maxminddb:"country"`
}

func loadDB() error {
	reader, err := maxminddb.Open(dbPath)
	if err != nil {
		return err
	}
	dbMu.Lock()
	if db != nil {
		db.Close()
	}
	db = reader
	dbMu.Unlock()
	log.Println("database loaded")
	return nil
}

func dbWatcher() {
	var lastMod time.Time
	for {
		time.Sleep(10 * time.Second)
		fi, err := os.Stat(dbPath)
		if err != nil {
			continue
		}
		if fi.ModTime().After(lastMod) {
			lastMod = fi.ModTime()
			if err := loadDB(); err != nil {
				log.Printf("failed to reload database: %v", err)
				lastMod = time.Time{}
			}
		}
	}
}

func healthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
}

func readyz(w http.ResponseWriter, r *http.Request) {
	dbMu.RLock()
	d := db
	dbMu.RUnlock()
	if d == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func countryHandler(w http.ResponseWriter, r *http.Request) {
	ipStr := r.PathValue("ip")
	if ipStr == "" {
		http.Error(w, "missing IP", http.StatusBadRequest)
		return
	}

	ip := net.ParseIP(ipStr)
	if ip == nil {
		http.Error(w, "invalid IP", http.StatusBadRequest)
		return
	}

	dbMu.RLock()
	d := db
	dbMu.RUnlock()
	if d == nil {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("nil"))
		return
	}

	var record countryRecord
	if err := d.Lookup(ip, &record); err != nil {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("nil"))
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(record.Country.ISOCode))
}

func main() {
	log.SetFlags(0)

	if err := loadDB(); err != nil {
		log.Printf("startup: could not load database (%v), starting without", err)
	}
	go dbWatcher()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthz)
	mux.HandleFunc("GET /readyz", readyz)
	mux.HandleFunc("GET /country/{ip}", countryHandler)

	srv := &http.Server{
		Addr:         ":8080",
		Handler:      mux,
		ReadTimeout:  2 * time.Second,
		WriteTimeout: 2 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	log.Printf("listening on :8080")
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
