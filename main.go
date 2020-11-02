package main

import (
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"time"
)

func handleMutate(w http.ResponseWriter, r *http.Request) {

	body, err := ioutil.ReadAll(r.Body)
	defer r.Body.Close()
	if err != nil {
		log.Println(err)
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprintf(w, "%s", err)
	}

	mutated, err := Mutate(body)
	if err != nil {
		log.Println(err)
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprintf(w, "%s", err)
	}

	w.WriteHeader(http.StatusOK)
	w.Write(mutated)
}

func main() {

	mux := http.NewServeMux()

	mux.HandleFunc("/mutate", handleMutate)

	s := &http.Server{
		Addr:           ":443",
		Handler:        mux,
		ReadTimeout:    10 * time.Second,
		WriteTimeout:   10 * time.Second,
		MaxHeaderBytes: 1 << 20, // 1048576
	}

	log.Fatal(s.ListenAndServeTLS("./mutateme.pem", "./mutateme.key"))

}
