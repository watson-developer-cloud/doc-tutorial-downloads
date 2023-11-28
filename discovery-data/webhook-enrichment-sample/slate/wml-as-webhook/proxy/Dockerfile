FROM icr.io/codeengine/golang:alpine
COPY proxy.go /
COPY go.mod /
RUN go build -ldflags '-s -w -extldflags "-static"' -o /proxy /proxy.go

# Copy the exe into a smaller base image
FROM icr.io/codeengine/alpine
COPY --from=0 /proxy /proxy
CMD /proxy