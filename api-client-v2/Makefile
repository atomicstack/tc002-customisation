.PHONY: build test vet completions

build:
	go build -trimpath -o bin/tc002 ./cmd/tc002

test:
	go test -race ./...

vet:
	go vet ./...

completions: build
	mkdir -p completions
	bin/tc002 completion bash > completions/tc002.bash
	bin/tc002 completion zsh > completions/_tc002
