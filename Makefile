#!/usr/bin/make -f

PACKAGES_SIMTEST=$(shell go list ./... | grep '/simulation')
VERSION := $(shell echo $(shell git describe --tags) | sed 's/^v//')
COMMIT := $(shell git log -1 --format='%H')
LEDGER_ENABLED ?= true
SDK_PACK := $(shell go list -m github.com/cosmos/cosmos-sdk | sed  's/ /\@/g')
BINDIR ?= $(GOPATH)/bin
SIMAPP = ./app

# for dockerized protobuf tools
DOCKER := $(shell which docker)
BUF_IMAGE=bufbuild/buf@sha256:3cb1f8a4b48bd5ad8f09168f10f607ddc318af202f5c057d52a45216793d85e5 #v1.4.0
DOCKER_BUF := $(DOCKER) run --rm -v $(CURDIR):/workspace --workdir /workspace $(BUF_IMAGE)
HTTPS_GIT := https://github.com/CosmWasm/wasmd.git


WILLCHAIN_CHAIN_ID="willchain-mainnet"
WILLCHAIN_DENOM=uwill
WILLCHAIN_NODE=http://localhost:26657

# WILLCHAIN_CHAIN_ID="willchain-testnet"
# WILLCHAIN_DENOM=uwill
# WILLCHAIN_NODE=http://192.168.1.100:26657

WILLCHAIN_CHAIN_ID_ARGS=--chain-id=$(WILLCHAIN_CHAIN_ID)
WILLCHAIN_NODE_ARGS=--node=$(WILLCHAIN_NODE)

export GO111MODULE = on

# process build tags

build_tags = netgo
ifeq ($(LEDGER_ENABLED),true)
  ifeq ($(OS),Windows_NT)
    GCCEXE = $(shell where gcc.exe 2> NUL)
    ifeq ($(GCCEXE),)
      $(error gcc.exe not installed for ledger support, please install or set LEDGER_ENABLED=false)
    else
      build_tags += ledger
    endif
  else
    UNAME_S = $(shell uname -s)
    ifeq ($(UNAME_S),OpenBSD)
      $(warning OpenBSD detected, disabling ledger support (https://github.com/cosmos/cosmos-sdk/issues/1988))
    else
      GCC = $(shell command -v gcc 2> /dev/null)
      ifeq ($(GCC),)
        $(error gcc not installed for ledger support, please install or set LEDGER_ENABLED=false)
      else
        build_tags += ledger
      endif
    endif
  endif
endif

ifeq ($(WITH_CLEVELDB),yes)
  build_tags += gcc
endif
build_tags += $(BUILD_TAGS)
build_tags := $(strip $(build_tags))

whitespace :=
empty = $(whitespace) $(whitespace)
comma := ,
build_tags_comma_sep := $(subst $(empty),$(comma),$(build_tags))

# process linker flags
#-X github.com/CosmWasm/wasmd/app.Bech32Prefix=wasm
ldflags = -X github.com/cosmos/cosmos-sdk/version.Name=wasm \
		  -X github.com/cosmos/cosmos-sdk/version.AppName=wasmd \
		  -X github.com/cosmos/cosmos-sdk/version.Version=$(VERSION) \
		  -X github.com/cosmos/cosmos-sdk/version.Commit=$(COMMIT) \
		  -X github.com/CosmWasm/wasmd/app.Bech32Prefix=rug \
		  -X "github.com/cosmos/cosmos-sdk/version.BuildTags=$(build_tags_comma_sep)"

ifeq ($(WITH_CLEVELDB),yes)
  ldflags += -X github.com/cosmos/cosmos-sdk/types.DBBackend=cleveldb
endif
ifeq ($(LINK_STATICALLY),true)
	ldflags += -linkmode=external -extldflags "-Wl,-z,muldefs -static"
endif
ldflags += $(LDFLAGS)
ldflags := $(strip $(ldflags))

BUILD_FLAGS := -tags "$(build_tags_comma_sep)" -ldflags '$(ldflags)' -trimpath

# The below include contains the tools and runsim targets.
include contrib/devtools/Makefile

all: install lint test

build: go.sum
ifeq ($(OS),Windows_NT)
	$(error wasmd server not supported. Use "make build-windows-client" for client)
	exit 1
else
	go build $(BUILD_FLAGS) -o build/wasmd ./cmd/wasmd
#go build $(BUILD_FLAGS) -o build/wasmd ./cmd/wasmd
endif

build-windows-client: go.sum
	GOOS=windows GOARCH=amd64 go build -mod=readonly $(BUILD_FLAGS) -o build/wasmd.exe ./cmd/wasmd

build-contract-tests-hooks:
ifeq ($(OS),Windows_NT)
	go build -mod=readonly $(BUILD_FLAGS) -o build/contract_tests.exe ./cmd/contract_tests
else
	go build -mod=readonly $(BUILD_FLAGS) -o build/contract_tests ./cmd/contract_tests
endif

install: go.sum
	go install -mod=readonly $(BUILD_FLAGS) ./cmd/wasmd

########################################
### Tools & dependencies

go-mod-cache: go.sum
	@echo "--> Download go modules to local cache"
	@go mod download

go.sum: go.mod
	@echo "--> Ensure dependencies have not been modified"
	@go mod verify

draw-deps:
	@# requires brew install graphviz or apt-get install graphviz
	go install github.com/RobotsAndPencils/goviz@latest
	@goviz -i ./cmd/wasmd -d 2 | dot -Tpng -o dependency-graph.png

clean:
	rm -rf snapcraft-local.yaml build/

distclean: clean
	rm -rf vendor/

########################################
### Testing

test: test-unit
test-all: test-race test-cover test-system

test-unit:
	@VERSION=$(VERSION) go test -mod=readonly -tags='ledger test_ledger_mock' ./...

test-race:
	@VERSION=$(VERSION) go test -mod=readonly -race -tags='ledger test_ledger_mock' ./...

test-cover:
	@go test -mod=readonly -timeout 30m -race -coverprofile=coverage.txt -covermode=atomic -tags='ledger test_ledger_mock' ./...

benchmark:
	@go test -mod=readonly -bench=. ./...

test-sim-import-export: runsim
	@echo "Running application import/export simulation. This may take several minutes..."
	@$(BINDIR)/runsim -Jobs=4 -SimAppPkg=$(SIMAPP) -ExitOnFail 50 5 TestAppImportExport

test-sim-multi-seed-short: runsim
	@echo "Running short multi-seed application simulation. This may take awhile!"
	@$(BINDIR)/runsim -Jobs=4 -SimAppPkg=$(SIMAPP) -ExitOnFail 50 5 TestFullAppSimulation

test-sim-deterministic: runsim
	@echo "Running application deterministic simulation. This may take awhile!"
	@$(BINDIR)/runsim -Jobs=4 -SimAppPkg=$(SIMAPP) -ExitOnFail 1 1 TestAppStateDeterminism

test-system: install
	$(MAKE) -C tests/system/ test

###############################################################################
###                                Linting                                  ###
###############################################################################

format-tools:
	go install mvdan.cc/gofumpt@v0.4.0
	go install github.com/client9/misspell/cmd/misspell@v0.3.4
	go install github.com/daixiang0/gci@v0.11.2

lint: format-tools
	golangci-lint run --tests=false
	find . -name '*.go' -type f -not -path "./vendor*" -not -path "./tests/system/vendor*" -not -path "*.git*" -not -path "*_test.go" | xargs gofumpt -d

format: format-tools
	find . -name '*.go' -type f -not -path "./vendor*" -not -path "./tests/system/vendor*" -not -path "*.git*" -not -path "./client/lcd/statik/statik.go" | xargs gofumpt -w
	find . -name '*.go' -type f -not -path "./vendor*" -not -path "./tests/system/vendor*" -not -path "*.git*" -not -path "./client/lcd/statik/statik.go" | xargs misspell -w
	find . -name '*.go' -type f -not -path "./vendor*" -not -path "./tests/system/vendor*" -not -path "*.git*" -not -path "./client/lcd/statik/statik.go" | xargs gci write --skip-generated -s standard -s default -s "prefix(cosmossdk.io)" -s "prefix(github.com/cosmos/cosmos-sdk)" -s "prefix(github.com/CosmWasm/wasmd)" --custom-order


###############################################################################
###                                Protobuf                                 ###
###############################################################################
protoVer=0.14.0
protoImageName=ghcr.io/cosmos/proto-builder:$(protoVer)
protoImage=$(DOCKER) run --rm -v $(CURDIR):/workspace --workdir /workspace $(protoImageName)

proto-all: proto-format proto-lint proto-gen format

proto-gen:
	@echo "Generating Protobuf files"
	@$(protoImage) sh ./scripts/protocgen.sh

proto-format:
	@echo "Formatting Protobuf files"
	@$(protoImage) find ./ -name "*.proto" -exec clang-format -i {} \;

proto-swagger-gen:
	@./scripts/protoc-swagger-gen.sh

proto-lint:
	@$(DOCKER_BUF) lint --error-format=json

proto-check-breaking:
	@$(DOCKER_BUF) breaking --against $(HTTPS_GIT)#branch=main

.PHONY: all install install-debug \
	go-mod-cache draw-deps clean build format \
	test test-all test-build test-cover test-unit test-race \
	test-sim-import-export build-windows-client \
	test-system












################################
start:
	./build/wasmd start --home ./private/.wasmapp
_env_:
	export PATH=$PATH:$(go env GOPATH)/bin
_clean_:
	go clean -modcache
save:
	git add * -v; git commit -am "autosave"; git push
alice_test: alice_d alice_c
	echo "done"
alice_c:
	./build/wasmd keys add alice --recover
alice_d:
	 ./build/wasmd keys delete alice 
alice_balance:
	./build/wasmd q bank balances will1p0k8gygawzpggzwftv7cv47zvgg8zaun7h2v28 $(WILLCHAIN_NODE_ARGS)
will_test: will_cx
	echo "Done with will tests"

### TODO: both will_create and claim_schnorr shouldn't accept all schnor claim params..... makes no sense lol
### start by removing sig from schnorr


# will
ADDRESS=will1p0k8gygawzpggzwftv7cv47zvgg8zaun7h2v28
WID=did:will:5ef8a4b1216ccc9290cad30c6a27b1d158442781615e32e5b5c5936da5130648
CID=7b028f1e-5842-4bc2-a73f-15de8371061b
# schnorr claim
SIGNATURE=7ab0edb9b0929b5bb4b47dfb927d071ecc5de75985662032bb52ef3c5ace640b165c6df5ea8911a6c0195a3140be5119a5b882e91b34cbcdd31ef3f5b0035b06
MESSAGE=message-2b-signed
PUBKEY=2320a2da28561875cedbb0c25ae458e0a1d087834ae49b96a3f93cec79a8190c
# pedersen claim
COMMITMENT=0xabc 
BLINDING_FACTOR=0000000000000000000000000000000000000000000000000000000000000000 
VALUE=0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798 

# gnark claim

# contract payload
HEX_PAYLOAD := $(shell printf '{"foo":"bar"}' | xxd -p | tr -d '\n')
will_cl:
	make will_create ; 
	sleep 5 ; 
	make will_list
will_create:
#wasm.will14hj2tavq8fpesdwxxcu44rty3hh90vhujrvcmstl4zr3txmfvw9s8dkg8
# fix this in the contract?
# acknowledgement:"{\"error\":\"Error parsing into type ibc_tutorial::msg::IbcExecuteMsg: Expected to parse either a `true`, `false`, or a `null`.\"}"
	./build/wasmd tx will create "test will ${i}" "will156mw28alhpenp4lknweat6432dux34uydx590v" 500 \
	--component-name "component_for_transfer_with_emit_output" --component-args "transfer:will1038e4lakn5krq0wz7u5rg74l7ayt4gxyn5duey,987654321,uwill" --component-output-type "emit" --component-output-args "transferred_the_tokens" \
	--component-name "component_for_schnorr_claim_with_transfer_output" --component-args "schnorr-private-will156mw28alhpenp4lknweat6432dux34uydx590v,a,b,c:${SIGNATURE},${PUBKEY},${MESSAGE}" --component-output-type "transfer" --component-output-args "will156mw28alhpenp4lknweat6432dux34uydx590v,1000000000,uwill"  \
	--component-name "component_for_pedersen_claim_with_ibc_send_output" --component-args "pedersen-private-will156mw28alhpenp4lknweat6432dux34uydx590v:commitment_hex,random_factor_hex,value_hex,blinding_factor_hex" --component-output-type "ibc_send" --component-output-args "channel-0,uwill,will156mw28alhpenp4lknweat6432dux34uydx590v,123" \
	--component-name "component_for_gnark_claim_with_contract_call_output" --component-args "gnark-private-will156mw28alhpenp4lknweat6432dux34uydx590v:verification_key_hex,public_inputs_hex,proof_hex" --component-output-type "contract_call" --component-output-args "0xcontract_address,${HEX_PAYLOAD}" \
	--component-name "component_for_ibc_msg_with_emit_output" --component-args "ibc_msg:channel-0,will,abc" --component-output-type "emit" --component-output-args "sent ibc message" \
	--from alice $(WILLCHAIN_CHAIN_ID_ARGS) -y $(WILLCHAIN_NODE_ARGS) 
	sleep 1
will_cx:
	@for i in {1..20}; do \
		echo "Running command $$i time(s)"; \
		i=$$i make will_c; \
	done

will_get:
	./build/wasmd query will get "${WID}" $(WILLCHAIN_NODE_ARGS) 
will_list:
	./build/wasmd query will list ${ADDRESS} $(WILLCHAIN_NODE_ARGS) 

# SCHNORR
will_claim_schnorr:
	./build/wasmd tx will claim "${WID}" "${CID}" "schnorr" "${SIGNATURE}:${PUBKEY}:${MESSAGE}" --from dev-wallet --chain-id willchain-mainnet -y
# will_claim_schnorr:
# 	@echo "Claiming with Schnorr verification..."
# 	@SIGNATURE="4aadcea21fe145eeb73a72a8eb3fac914c79c9c2efbf86e9ccc616bf94ede603"; \
# 	MESSAGE="message-2b-signed"; \
# 	PUBKEY="d214cbdf6be7646ef2a56c60bba6561dd2e19aea8e9d6f55d0923795a6edc107"; \
# 	./build/wasmd tx will claim "$${WID}" "$${CID}" "schnorr" "$${SIGNATURE}:$${MESSAGE}:$${PUBKEY}" --from alice --chain-id willchain-mainnet -y
# PEDERSEN
will_claim_pedersen:
	./build/wasmd tx will claim "${WID}" "${CID}" "pedersen" "${COMMITMENT}:$(BLINDING_FACTOR):${VALUE}" --from dev-wallet --chain-id willchain-mainnet -y

# GNARK
will_claim_gnark:
	PROOF=0xabc
	PUBLIC_INPUTS=0000000000000000000000000000000000000000000000000000000000000000
	./build/wasmd tx will claim "${WID}" "${CID}" "gnark" "${PROOF}:${PUBLIC_INPUTS}" --from alice --chain-id willchain-mainnet -y
run:
	bash run.sh

###### TESTS
will_test_keeper:
	go test -v x/will/keeper/keeper_test.go
will_test_ibc:
# go test -v x/will/ibc_tests/ibc_test.go
	go test -v ./x/will/ibc_tests2/app_test.go

# deploy contracts
DEV_WALLET=alice
CODE_ID=1
DEPLOYED_CONTRACT_ADDRESS=will14hj2tavq8fpesdwxxcu44rty3hh90vhujrvcmstl4zr3txmfvw9srdqyxn
# DEPLOYED_CONTRACT_ADDRESS=w3ll14hj2tavq8fpesdwxxcu44rty3hh90vhujrvcmstl4zr3txmfvw9srdqyxn

# dc1:
# ./build/wasmd tx wasm store ./wasm_artifacts/simple_option.wasm --from $(DEV_WALLET) --gas auto --gas-adjustment 1.3 -y -b sync --output json $(WILLCHAIN_NODE_ARGS) $(WILLCHAIN_CHAIN_ID_ARGS)
dc:
	./build/wasmd tx wasm store ./wasm_artifacts/ibc_tutorial.wasm --from $(DEV_WALLET) --gas auto --gas-adjustment 1.3 -y -b sync --output json $(WILLCHAIN_NODE_ARGS) $(WILLCHAIN_CHAIN_ID_ARGS)
check:
	./build/wasmd q wasm code-info $(CODE_ID)
instantiate:
	./build/wasmd tx wasm instantiate $(CODE_ID) \
	"{}" \
	--amount="1uwill" --no-admin --label "test ibc" --from ${DEV_WALLET} --gas auto --gas-adjustment 1.3 -b sync -y $(WILLCHAIN_NODE_ARGS) $(WILLCHAIN_CHAIN_ID_ARGS)
contract_address:
	./build/wasmd q wasm list-contract-by-code $(CODE_ID) --output json $(WILLCHAIN_NODE_ARGS)
	CONTRACT_ADDRESS=$(shell ./build/wasmd q wasm list-contract-by-code $(CODE_ID) --output json $(WILLCHAIN_NODE_ARGS) ')
	echo $$CONTRACT_ADDRESS
contract_info:
	./build/wasmd q wasm contract $(DEPLOYED_CONTRACT_ADDRESS) --output json $(WILLCHAIN_NODE_ARGS)

fund_dev:
	./build/wasmd tx bank send alice will1038e4lakn5krq0wz7u5rg74l7ayt4gxyn5duey 10uwill --broadcast-mode="sync" --chain-id="willchain-mainnet" --yes
# dev
# mainnet - wasm.w3ll14hj2tavq8fpesdwxxcu44rty3hh90vhujrvcmstl4zr3txmfvw9srdqyxn
# testnet - wasm.w3ll14hj2tavq8fpesdwxxcu44rty3hh90vhujrvcmstl4zr3txmfvw9srdqyxn

# build warnings
# 0xjovi@0xjovis-MacBook-Pro wasmd % go get github.com/CosmWasm/wasmd/x/will/keeper
# go: module github.com/golang/protobuf is deprecated: Use the "google.golang.org/protobuf" module instead.
# go: warning: github.com/cometbft/cometbft@v0.38.2: retracted by module author: superseeded by v0.38.3 because of ASA-2024-001
# go: warning: github.com/cosmos/ibc-go/v8@v8.0.0: retracted by module author: contains ASA-2024-007 vulnerability
# go: to switch to the latest unretracted version, run:
#         go get <module>@latest



# FOR KEPLR
# {
# 	"chainId": "willchain-mainnet",
# 	"chainName": "willchain",
# 	"rpc": "http://127.0.0.1:26557",
# 	"rest": "http://127.0.0.1:1317",
# 	"bip44": {
# 		"coinType": 118
# 	},
# 	"coinType": 118,
# 	"bech32Config": {
# 		"bech32PrefixAccAddr": "will",
# 		"bech32PrefixAccPub": "willpub",
# 		"bech32PrefixValAddr": "willvaloper",
# 		"bech32PrefixValPub": "willvaloperpub",
# 		"bech32PrefixConsAddr": "willvalcons",
# 		"bech32PrefixConsPub": "willvalconspub"
# 	},
# 	"currencies": [
# 		{
# 			"coinDenom": "WILL",
# 			"coinMinimalDenom": "uwill",
# 			"coinDecimals": 6,
# 			"coinGeckoId": "willchain"
# 		}
# 	],
# 	"feeCurrencies": [
# 		{
# 			"coinDenom": "WILL",
# 			"coinMinimalDenom": "uwill",
# 			"coinDecimals": 6,
# 			"coinGeckoId": "willchain",
# 			"gasPriceStep": {
# 				"low": 0.01,
# 				"average": 0.025,
# 				"high": 0.03
# 			}
# 		}
# 	],
# 	"gasPriceStep": {
# 		"low": 0.01,
# 		"average": 0.025,
# 		"high": 0.03
# 	},
# 	"stakeCurrency": {
# 		"coinDenom": "WILL",
# 		"coinMinimalDenom": "uwill",
# 		"coinDecimals": 6,
# 		"coinGeckoId": "willchain"
# 	},
# 	"features": []
# }
