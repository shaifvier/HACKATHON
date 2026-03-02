package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
	"time"

	"github.com/hyperledger/fabric-chaincode-go/shim"
	"github.com/hyperledger/fabric-contract-api-go/contractapi"
	oqs "github.com/open-quantum-safe/liboqs-go/oqs"
)

type SmartContract struct {
	contractapi.Contract
}

type ReputationRecord struct {
	ID               string `json:"id"`
	Reputation       int    `json:"reputation"`
	Signature        string `json:"signature"`
	SigningPublicKey string `json:"signingPublicKey"`
	UpdatedAt        string `json:"updatedAt"`
}

const reputationPrefix = "reputation:"

func reputationKey(id string) string {
	return reputationPrefix + id
}

func reputationMessageDigest(id string, reputation int) []byte {
	message := fmt.Sprintf("%s:%d", id, reputation)
	digest := sha256.Sum256([]byte(message))
	return digest[:]
}

func VerifyPQCSignature(message []byte, sigB64, pubKeyB64 string) bool {
	sigBytes, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil {
		fmt.Println("decode sig:", err)
		return false
	}

	pubBytes, err := base64.StdEncoding.DecodeString(pubKeyB64)
	if err != nil {
		fmt.Println("decode pub:", err)
		return false
	}

	var sig oqs.Signature
	defer sig.Clean()
	if err := sig.Init("Dilithium5", nil); err != nil {
		fmt.Println("init oqs:", err)
		return false
	}

	start := time.Now()
	isValid, err := sig.Verify(message, sigBytes, pubBytes)
	fmt.Printf("Dilithium5 verify time: %s\n", time.Since(start))
	if err != nil {
		fmt.Println("verify error:", err)
		return false
	}
	return isValid
}

func (s *SmartContract) SetReputation(
	ctx contractapi.TransactionContextInterface,
	id string,
	reputation int,
	signature string,
	signingPublicKey string,
) error {
	if id == "" {
		return fmt.Errorf("id is required")
	}
	if reputation < 0 {
		return fmt.Errorf("reputation must be >= 0")
	}

	digest := reputationMessageDigest(id, reputation)
	if !VerifyPQCSignature(digest, signature, signingPublicKey) {
		return fmt.Errorf("invalid PQC signature for reputation update")
	}

	record := ReputationRecord{
		ID:               id,
		Reputation:       reputation,
		Signature:        signature,
		SigningPublicKey: signingPublicKey,
		UpdatedAt:        time.Now().UTC().Format(time.RFC3339Nano),
	}

	b, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("marshal reputation record failed: %w", err)
	}

	if err := ctx.GetStub().PutState(reputationKey(id), b); err != nil {
		return fmt.Errorf("failed to store reputation: %w", err)
	}

	payload, _ := json.Marshal(record)
	return ctx.GetStub().SetEvent("ReputationUpdated", payload)
}

func (s *SmartContract) GetReputation(
	ctx contractapi.TransactionContextInterface,
	id string,
) (*ReputationRecord, error) {
	if id == "" {
		return nil, fmt.Errorf("id is required")
	}

	raw, err := ctx.GetStub().GetState(reputationKey(id))
	if err != nil {
		return nil, fmt.Errorf("failed to read reputation: %w", err)
	}
	if len(raw) == 0 {
		return nil, fmt.Errorf("reputation not found for id")
	}

	var record ReputationRecord
	if err := json.Unmarshal(raw, &record); err != nil {
		return nil, fmt.Errorf("failed to parse reputation record: %w", err)
	}

	return &record, nil
}

func (s *SmartContract) VerifyReputationSignature(
	ctx contractapi.TransactionContextInterface,
	id string,
) (bool, error) {
	record, err := s.GetReputation(ctx, id)
	if err != nil {
		return false, err
	}

	digest := reputationMessageDigest(record.ID, record.Reputation)
	ok := VerifyPQCSignature(digest, record.Signature, record.SigningPublicKey)
	return ok, nil
}

func main() {
	config := struct {
		CCID    string
		Address string
	}{
		CCID:    os.Getenv("CHAINCODE_ID"),
		Address: os.Getenv("CHAINCODE_SERVER_ADDRESS"),
	}

	chaincode, err := contractapi.NewChaincode(&SmartContract{})
	if err != nil {
		log.Panicf("Error creating chaincode: %s", err)
	}

	server := &shim.ChaincodeServer{
		CCID:     config.CCID,
		Address:  config.Address,
		CC:       chaincode,
		TLSProps: getTLSProperties(),
	}

	if err := server.Start(); err != nil {
		log.Panicf("Error starting chaincode server: %s", err)
	}
}

func getTLSProperties() shim.TLSProperties {
	tlsDisabledStr := getEnvOrDefault("CHAINCODE_TLS_DISABLED", "true")
	key := getEnvOrDefault("CHAINCODE_TLS_KEY", "")
	cert := getEnvOrDefault("CHAINCODE_TLS_CERT", "")
	clientCACert := getEnvOrDefault("CHAINCODE_CLIENT_CA_CERT", "")

	tlsDisabled := getBoolOrDefault(tlsDisabledStr, false)
	var keyBytes, certBytes, clientCACertBytes []byte
	var err error

	if !tlsDisabled {
		keyBytes, err = os.ReadFile(key)
		if err != nil {
			log.Panicf("error while reading the crypto file: %s", err)
		}
		certBytes, err = os.ReadFile(cert)
		if err != nil {
			log.Panicf("error while reading the crypto file: %s", err)
		}
	}

	if clientCACert != "" {
		clientCACertBytes, err = os.ReadFile(clientCACert)
		if err != nil {
			log.Panicf("error while reading the crypto file: %s", err)
		}
	}

	return shim.TLSProperties{
		Disabled:      tlsDisabled,
		Key:           keyBytes,
		Cert:          certBytes,
		ClientCACerts: clientCACertBytes,
	}
}

func getEnvOrDefault(env, defaultVal string) string {
	value, ok := os.LookupEnv(env)
	if !ok {
		value = defaultVal
	}
	return value
}

func getBoolOrDefault(value string, defaultVal bool) bool {
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return defaultVal
	}
	return parsed
}
