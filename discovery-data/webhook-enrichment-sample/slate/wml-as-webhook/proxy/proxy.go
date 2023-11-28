package main

import (
    "crypto/tls"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
)

func main() {
	target, err := url.Parse(fmt.Sprintf("https://%s/ml/v4/deployments/%s/predictions?version=2021-05-01", os.Getenv("SCORING_API_HOSTNAME"), os.Getenv("SCORING_DEPLOYMENT_ID")))
	if err != nil {
		panic(err)
	}
	log.Printf("forwarding to -> %s\n", target)

	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.Transport = &http.Transport {
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}

	originalDirector := proxy.Director
	proxy.Director = func(r *http.Request) {
		originalDirector(r)
		body := make([]byte, r.ContentLength)
		r.Body.Read(body)
		new_content := fmt.Sprintf("{\"input_data\":[{\"values\":[[%s]]}]}", body)
		r.Body = io.NopCloser(strings.NewReader(new_content))
		r.ContentLength = int64(len(new_content))
		r.Host = r.URL.Host // possibly required for virtualhost
		r.URL.Path = target.Path // to prevent proxy from appending path component
		r.Header.Del("Forwarded")
		r.Header.Del("X-Forwarded-For")
		r.Header.Del("X-Forwarded-Host")
		r.Header.Del("X-Forwarded-Proto")
	}

	http.Handle("/webhook", proxy)

	err = http.ListenAndServe(":8080", nil)
	if err != nil {
		panic(err)
	}
}