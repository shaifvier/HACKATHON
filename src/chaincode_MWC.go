package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
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
	verboseLogf(
		"PQC_VERIFY_START alg=Dilithium5 msg_sha256=%s sig_b64_prefix=%s pub_b64_prefix=%s",
		sha256Hex(message),
		previewForLog(sigB64),
		previewForLog(pubKeyB64),
	)

	sigBytes, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil {
		fmt.Println("decode sig:", err)
		verboseLogf("PQC_VERIFY_FAIL reason=decode_signature err=%v", err)
		return false
	}

	pubBytes, err := base64.StdEncoding.DecodeString(pubKeyB64)
	if err != nil {
		fmt.Println("decode pub:", err)
		verboseLogf("PQC_VERIFY_FAIL reason=decode_public_key err=%v", err)
		return false
	}

	verboseLogf("PQC_VERIFY_INPUT sig_len=%d pub_len=%d", len(sigBytes), len(pubBytes))

	var sig oqs.Signature
	defer sig.Clean()
	if err := sig.Init("Dilithium5", nil); err != nil {
		fmt.Println("init oqs:", err)
		verboseLogf("PQC_VERIFY_FAIL reason=init_oqs err=%v", err)
		return false
	}

	start := time.Now()
	isValid, err := sig.Verify(message, sigBytes, pubBytes)
	fmt.Printf("Dilithium5 verify time: %s\n", time.Since(start))
	if err != nil {
		fmt.Println("verify error:", err)
		verboseLogf("PQC_VERIFY_FAIL reason=verify_call err=%v", err)
		return false
	}
	verboseLogf("PQC_VERIFY_RESULT valid=%t elapsed=%s", isValid, time.Since(start))
	return isValid
}

func (s *SmartContract) SetReputation(
	ctx contractapi.TransactionContextInterface,
	id string,
	reputation int,
	signature string,
	signingPublicKey string,
) error {
	verboseLogf("SET_REPUTATION_REQUEST id=%s reputation=%d", id, reputation)

	if id == "" {
		return fmt.Errorf("id is required")
	}
	if reputation < 0 {
		return fmt.Errorf("reputation must be >= 0")
	}

	digest := reputationMessageDigest(id, reputation)
	verboseLogf("SET_REPUTATION_DIGEST id=%s digest_sha256=%s", id, sha256Hex(digest))
	if !VerifyPQCSignature(digest, signature, signingPublicKey) {
		verboseLogf("SET_REPUTATION_REJECTED id=%s reason=invalid_pqc_signature", id)
		return fmt.Errorf("invalid PQC signature for reputation update")
	}

	updatedAt, err := txTimestampRFC3339Nano(ctx)
	if err != nil {
		return err
	}

	record := ReputationRecord{
		ID:               id,
		Reputation:       reputation,
		Signature:        signature,
		SigningPublicKey: signingPublicKey,
		UpdatedAt:        updatedAt,
	}

	b, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("marshal reputation record failed: %w", err)
	}

	if err := ctx.GetStub().PutState(reputationKey(id), b); err != nil {
		return fmt.Errorf("failed to store reputation: %w", err)
	}

	verboseLogf(
		"SET_REPUTATION_STORED id=%s reputation=%d updated_at=%s tx_id=%s",
		id,
		reputation,
		record.UpdatedAt,
		ctx.GetStub().GetTxID(),
	)

	payload, _ := json.Marshal(record)
	return ctx.GetStub().SetEvent("ReputationUpdated", payload)
}

func txTimestampRFC3339Nano(ctx contractapi.TransactionContextInterface) (string, error) {
	ts, err := ctx.GetStub().GetTxTimestamp()
	if err != nil {
		return "", fmt.Errorf("failed to read tx timestamp: %w", err)
	}
	return time.Unix(ts.Seconds, int64(ts.Nanos)).UTC().Format(time.RFC3339Nano), nil
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
	verboseLogf("VERIFY_REPUTATION_SIGNATURE_REQUEST id=%s", id)

	record, err := s.GetReputation(ctx, id)
	if err != nil {
		return false, err
	}

	digest := reputationMessageDigest(record.ID, record.Reputation)
	ok := VerifyPQCSignature(digest, record.Signature, record.SigningPublicKey)
	verboseLogf("VERIFY_REPUTATION_SIGNATURE_RESULT id=%s valid=%t", id, ok)
	return ok, nil
}

func sha256Hex(data []byte) string {
	d := sha256.Sum256(data)
	return hex.EncodeToString(d[:])
}

func previewForLog(value string) string {
	if len(value) <= 16 {
		return value
	}
	return value[:16] + "..."
}

func verboseLogsEnabled() bool {
	value := getEnvOrDefault("VERBOSE_LOGS", "true")
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return true
	}
	return parsed
}

func verboseLogf(format string, args ...any) {
	if verboseLogsEnabled() {
		log.Printf(format, args...)
	}
}

func main() {
	log.Printf("VERBOSE_LOGS=%t", verboseLogsEnabled())

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
