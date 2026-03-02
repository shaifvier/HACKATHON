package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/hyperledger/fabric-chaincode-go/shim"
	"github.com/hyperledger/fabric-contract-api-go/contractapi"
	oqs "github.com/open-quantum-safe/liboqs-go/oqs"
)

// ================================
// Types & Constants
// ================================

// SmartContract struct
type SmartContract struct {
	contractapi.Contract
}

// ControllerIdentity structure stored in the blockchain
type ControllerIdentity struct {
	CID          string `json:"cid"`
	Hash         string `json:"hash"`
	DilithiumB64 string `json:"dilithiumB64"` // NEW: sender’s Dilithium public key (Base64)
	SigVersion   int    `json:"sigVersion"`   // NEW: start at 1; enable future rotation
}

// PQCKey struct represents a stored PQC public key
type PQCKey struct {
	KeyID        string `json:"keyID"`
	PublicKey    string `json:"publicKey"`
	Signature    string `json:"signature"`
	Version      int    `json:"version"`
	PreviousHash string `json:"previousHash"`
	//	Approvals    []string `json:"approvals"`
	Approved   bool   `json:"approved"`
	ApprovedAt string `json:"approvedAt"`
	Owner      string `json:"owner"`
}

// Used for debugging approvals
type ApprovalStatus struct {
	KeyID      string   `json:"keyID"`
	Owner      string   `json:"owner"`
	Approved   bool     `json:"approved"`
	ApprovedAt string   `json:"approvedAt"`
	Approvals  []string `json:"approvals"`
	Count      int      `json:"count"`
	Threshold  int      `json:"threshold"`
	Version    int      `json:"version"`
}

const (
	stateControllers = "SDNControllers"
	modePoC          = false // toggle: true = auto-approve on submit, false = require approvals
)

// ================================
// Utility helpers
// ================================

// Composite key namespace for approvals
const idxApproval = "approval"

const prefixApprovalCount = "approvalCount:"

func approvalCountKey(keyID string) string {
	return prefixApprovalCount + keyID
}

// helper: construct ApprovalStatus from a key + approvals info
func makeApprovalStatus(k *PQCKey, threshold, count int, ids []string) *ApprovalStatus {
	return &ApprovalStatus{
		KeyID:      k.KeyID,
		Owner:      k.Owner,
		Approved:   k.Approved,
		ApprovedAt: k.ApprovedAt,
		Approvals:  ids,
		Count:      count,
		Threshold:  threshold,
		Version:    k.Version,
	}
}

func readApprovalCount(ctx contractapi.TransactionContextInterface, keyID string) (int, error) {
	b, err := ctx.GetStub().GetState(approvalCountKey(keyID))
	if err != nil {
		return 0, fmt.Errorf("read approval counter failed: %w", err)
	}
	if len(b) == 0 {
		return 0, nil // default
	}
	n, err := strconv.Atoi(string(b))
	if err != nil {
		return 0, fmt.Errorf("counter parse error: %w", err)
	}
	return n, nil
}

func writeApprovalCount(ctx contractapi.TransactionContextInterface, keyID string, n int) error {
	return ctx.GetStub().PutState(approvalCountKey(keyID), []byte(strconv.Itoa(n)))
}

// Build composite key for (keyID, approverID)
func approvalCompositeKey(ctx contractapi.TransactionContextInterface, keyID, approverID string) (string, error) {
	return ctx.GetStub().CreateCompositeKey(idxApproval, []string{keyID, approverID})
}

// Check if approver already approved keyID
func hasApproval(ctx contractapi.TransactionContextInterface, keyID, approverID string) (bool, error) {
	ck, err := approvalCompositeKey(ctx, keyID, approverID)
	if err != nil {
		return false, err
	}
	val, err := ctx.GetStub().GetState(ck)
	if err != nil {
		return false, err
	}
	return len(val) != 0, nil
}

// Count approvals for keyID and optionally collect approver IDs
func countApprovals(ctx contractapi.TransactionContextInterface, keyID string, wantIDs bool) (int, []string, error) {
	iter, err := ctx.GetStub().GetStateByPartialCompositeKey(idxApproval, []string{keyID})
	if err != nil {
		return 0, nil, fmt.Errorf("index scan failed: %w", err)
	}
	defer iter.Close()

	total := 0
	// ensure non-nil when wantIDs
	var ids []string
	if wantIDs {
		ids = make([]string, 0) // <-- key line
	}

	for iter.HasNext() {
		kv, err := iter.Next()
		if err != nil {
			return 0, nil, fmt.Errorf("index read error: %w", err)
		}
		total++
		if wantIDs {
			_, attrs, err := ctx.GetStub().SplitCompositeKey(kv.Key)
			if err == nil && len(attrs) == 2 {
				ids = append(ids, attrs[1])
			}
		}
	}
	return total, ids, nil
}

// WhoAmI returns the exact GetID() string for the invoker.
func (s *SmartContract) WhoAmI(ctx contractapi.TransactionContextInterface) (string, error) {
	id, err := ctx.GetClientIdentity().GetID()
	if err != nil {
		return "", err
	}
	return id, nil
}

func getInvokerID(ctx contractapi.TransactionContextInterface) (string, error) {
	return ctx.GetClientIdentity().GetID()
}

// ComputeSHA256 generates a SHA-256 hash of the input
func ComputeSHA256(input string) string {
	hash := sha256.Sum256([]byte(input))
	return base64.StdEncoding.EncodeToString(hash[:])
}

// Reduces the EncryptionKeys into Base64 fomat to save transaction space for keys
func keyIDFromPubKeyB64(pubB64 string) string {
	h := sha256.Sum256([]byte(pubB64))
	return "key:" + base64.StdEncoding.EncodeToString(h[:16]) // short id
}

// Load/save controller set (empty slice if none)
func (s *SmartContract) loadControllers(ctx contractapi.TransactionContextInterface) ([]ControllerIdentity, error) {
	data, err := ctx.GetStub().GetState(stateControllers)
	if err != nil {
		return nil, fmt.Errorf("failed to read controllers: %w", err)
	}
	if len(data) == 0 {
		return []ControllerIdentity{}, nil
	}
	var cs []ControllerIdentity
	if err := json.Unmarshal(data, &cs); err != nil {
		return nil, fmt.Errorf("failed to parse controller list: %w", err)
	}
	return cs, nil
}

func (s *SmartContract) saveControllers(ctx contractapi.TransactionContextInterface, cs []ControllerIdentity) error {
	b, err := json.Marshal(cs)
	if err != nil {
		return fmt.Errorf("failed to marshal controllers: %w", err)
	}
	return ctx.GetStub().PutState(stateControllers, b)
}

// Checks if a controller is registered
func (s *SmartContract) isRegistered(ctx contractapi.TransactionContextInterface, id string) (bool, error) {
	cs, err := s.loadControllers(ctx)
	if err != nil {
		return false, err
	}
	for _, c := range cs {
		if c.CID == id {
			return true, nil
		}
	}
	return false, nil
}

// Used as a FLAG for Submit and Approval of keys
func (s *SmartContract) requireRegistered(ctx contractapi.TransactionContextInterface) (string, error) {
	invoker, err := getInvokerID(ctx)
	if err != nil {
		return "", fmt.Errorf("ERR_ID: cannot get invoker id: %w", err)
	}
	ok, err := s.isRegistered(ctx, invoker)
	if err != nil {
		return "", fmt.Errorf("ERR_CTRL_LOOKUP: %w", err)
	}
	if !ok {
		return "", fmt.Errorf("ERR_NOT_REGISTERED: invoker not a registered controller")
	}
	return invoker, nil
}

// GetDynamicApprovalThreshold calculates a 2/3 majority threshold for SDN controller approvals
func (s *SmartContract) GetDynamicApprovalThreshold(ctx contractapi.TransactionContextInterface) (int, error) {
	cs, err := s.loadControllers(ctx)
	if err != nil {
		return 0, fmt.Errorf("cannot load controllers: %w", err)
	}
	n := len(cs)
	if n <= 1 {
		return 1, nil
	}
	return (2*n + 2) / 3, nil // ceil(2n/3)
}

// VerifyPQCSignature verifies a PQC signature using Dilithium5
// sigB64: signature (B64), pubKeyB64: Dilithium public key (B64)
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

// getPreviousKeyInfo retrieves the latest key for a controller (if any),
// returning its keyID, version, and the key struct itself.
// If no previous key exists, prevVersion = 0 and keyID = "".
func (s *SmartContract) getPreviousKeyInfo(
	ctx contractapi.TransactionContextInterface,
	controllerID string,
) (prevKeyID string, prevVersion int, prevKey *PQCKey, err error) {

	latestPtr := "latestKey:" + controllerID
	data, err := ctx.GetStub().GetState(latestPtr)
	if err != nil {
		return "", 0, nil, fmt.Errorf("failed to read latest pointer: %w", err)
	}
	if len(data) == 0 {
		//no previous key
		return "", 0, nil, nil
	}

	prevKeyID = string(data)
	prevJSON, err := ctx.GetStub().GetState(prevKeyID)
	if err != nil {
		return "", 0, nil, fmt.Errorf("failed to read previous key: %w", err)
	}
	if len(prevJSON) == 0 {
		// Pointer exists but object missing → treat as none
		return prevKeyID, 0, nil, nil
	}

	var prev PQCKey
	if err := json.Unmarshal(prevJSON, &prev); err != nil {
		return "", 0, nil, fmt.Errorf("failed to parse previous key: %w", err)
	}
	return prevKeyID, prev.Version, &prev, nil
}

// ================================
// Public contract methods
// ================================

// RegisterController registers invoker as a controller.
// 'pqcSignature' is a Dilithium signature over the raw bytes of callerID (GetID()) or its hash.
// Here we verify over the raw callerID bytes (as provided).

func (s *SmartContract) RegisterController(ctx contractapi.TransactionContextInterface, pqcSignature string, signingPublicKey string) error {
	// Get unique caller identity (includes CN, O, OU, etc.)
	callerID, err := getInvokerID(ctx)
	if err != nil {
		return fmt.Errorf("failed to get caller identity: %v", err)
	}
	fmt.Println("CALLERID:", callerID)

	// Verify PQC Signature (signing message is callerID)
	if !VerifyPQCSignature([]byte(callerID), pqcSignature, signingPublicKey) {
		return fmt.Errorf("PQC Signature verification failed. Unauthorized registration.")
	}

	// Generate binding hash: SHA256(callerID + pqcSignature)
	hashBinding := ComputeSHA256(callerID + pqcSignature)

	// Retrieve registered controllers
	controllers, err := s.loadControllers(ctx)
	if err != nil {
		return err
	}

	// Prevent duplicate registration
	for _, existing := range controllers {
		if existing.CID == callerID {
			return fmt.Errorf("controller already registered")
		}
	}

	// Register new controller
	controllers = append(controllers, ControllerIdentity{
		CID:          callerID,
		Hash:         hashBinding,
		DilithiumB64: signingPublicKey, // <— pin Dilithium pubkey here
		SigVersion:   1,
	})

	if err := s.saveControllers(ctx, controllers); err != nil {
		return fmt.Errorf("failed to save controller list: %v", err)
	}
	return nil
}

// RemoveController deletes an SDN controller
func (s *SmartContract) RemoveController(ctx contractapi.TransactionContextInterface, pqcSignature string, signingPublicKey string) error {
	// Get X.509 ID from caller
	callerID, err := getInvokerID(ctx)
	if err != nil {
		return fmt.Errorf("failed to get caller identity: %v", err)
	}

	// callerIdentity := &msp.SerializedIdentity{}
	// err = proto.Unmarshal(callerBytes, callerIdentity)
	// if err != nil {
	// 	return fmt.Errorf("failed to unmarshal caller identity: %v", err)
	// }
	// callerID := callerIdentity.X.509
	fmt.Println("CALLER:", callerID)

	// Verify PQC Signature
	if !VerifyPQCSignature([]byte(callerID), pqcSignature, signingPublicKey) {
		return fmt.Errorf("PQC Signature verification failed. Unauthorized removal.")
	}
	controllers, err := s.loadControllers(ctx)
	if err != nil {
		return fmt.Errorf("failed to retrieve controller list: %v", err)
	}

	out := controllers[:0]
	for _, existing := range controllers {
		if existing.CID != callerID {
			out = append(out, existing)
		}
	}

	if err := s.saveControllers(ctx, out); err != nil {
		return fmt.Errorf("failed to save updated controller list: %v", err)
	}
	_ = ctx.GetStub().DelState("latestKey:" + callerID)
	_ = ctx.GetStub().DelState("latestApprovedKey:" + callerID)
	return nil
}

// public getter for the Dilithium key
func (s *SmartContract) GetDilithiumPubKey(
	ctx contractapi.TransactionContextInterface,
	controllerID string,
) (string, error) {
	cs, err := s.loadControllers(ctx)
	if err != nil {
		return "", err
	}
	for _, c := range cs {
		if c.CID == controllerID {
			if c.DilithiumB64 == "" {
				return "", fmt.Errorf("no Dilithium key for controller")
			}
			return c.DilithiumB64, nil
		}
	}
	return "", fmt.Errorf("controller not found")
}

// GetControllers retrieves all registered SDN controllers **PUBLIC**
func (s *SmartContract) GetControllers(ctx contractapi.TransactionContextInterface) ([]ControllerIdentity, error) {
	return s.loadControllers(ctx)
}

// SubmitKey stores a PQC public key after verification
// Args:
//   - encryptionPublicKey: Kyber pubkey (Base64)
//   - signature: Dilithium signature (Base64) over SHA256(raw Kyber pubkey bytes)
//   - signingPublicKey: Dilithium public key (Base64)
func (s *SmartContract) SubmitKey(ctx contractapi.TransactionContextInterface, encryptionPublicKey, signature, signingPublicKey string) error {

	invoker, err := s.requireRegistered(ctx)
	if err != nil {
		return err
	}

	// Verify PQC Signature using the correct signing public key (Dilithium5)
	// Recommend signing the hash for bounded message
	kyberPubBytes, err := base64.StdEncoding.DecodeString(encryptionPublicKey)
	if err != nil {
		return fmt.Errorf("bad kyber pubkey b64")
	}
	msg := sha256.Sum256(kyberPubBytes)
	if !VerifyPQCSignature(msg[:], signature, signingPublicKey) {
		return fmt.Errorf("invalid signature on Kyber key")
	}

	// Build new keyID from pubkey
	keyID := keyIDFromPubKeyB64(encryptionPublicKey)
	prevKeyID, prevVersion, prevKey, err := s.getPreviousKeyInfo(ctx, invoker)
	if err != nil {
		return err
	}

	// Guard against duplicate re-submit of the same pubkey
	if existing, err := ctx.GetStub().GetState(keyID); err == nil && len(existing) > 0 {
		var ek PQCKey
		if err := json.Unmarshal(existing, &ek); err == nil {
			if ek.Owner != invoker {
				return fmt.Errorf("ERR_DUPLICATE_KEY: public key already registered by another controller")
			}
			// If ek.Owner == invoker, it’s a duplicate; your later duplicate check will catch it.
		}
	}
	if prevKey != nil && prevKey.PublicKey == encryptionPublicKey {
		return fmt.Errorf("ERR_SAME_AS_LATEST: same public key already the latest for this controller")
	}

	// Version: start at 1 if no previous, otherwise prevVersion+1
	version := 1
	if prevVersion > 0 {
		version = prevVersion + 1
	}

	// Create and persist the new key (pending by default)
	nowRFC3339 := time.Now().UTC().Format(time.RFC3339Nano)
	pqcKey := PQCKey{
		KeyID:        keyID,
		PublicKey:    encryptionPublicKey, // Kyber1024 encryption public key
		Signature:    signature,           // Dilithium5 signature
		Version:      version,
		PreviousHash: prevKeyID, // auto-linked to previous key *ID*
		//Approvals:    []string{},
		Approved:   false,
		ApprovedAt: "",
		Owner:      invoker, // set owner
	}

	keyJSON, err := json.Marshal(pqcKey)
	if err != nil {
		return fmt.Errorf("marshal pqcKey: %w", err)
	}

	if err := ctx.GetStub().PutState(keyID, keyJSON); err != nil {
		return err
	}

	// update the “latest pointer” per controller
	latestPtr := "latestKey:" + invoker
	if err := ctx.GetStub().PutState(latestPtr, []byte(keyID)); err != nil {
		return err
	}

	// Write an audit-friendly composite index entry: ctrl~key:(controllerID, timestamp) -> keyID
	idxName := "ctrl~key"
	ck, _ := ctx.GetStub().CreateCompositeKey(idxName, []string{invoker, nowRFC3339})
	if err := ctx.GetStub().PutState(ck, []byte(keyID)); err != nil {
		return err
	}

	// Events: rotation (optional) + update
	if prevKeyID != "" {
		_ = ctx.GetStub().SetEvent("KeyRotated", []byte("KeyRotated:"+prevKeyID+"->"+keyID))
	}

	// Now handle PoC auto-approval by reusing ApproveKey logic.
	if modePoC {
		if err := s.ApproveKey(ctx, keyID); err != nil {
			// In case of idempotency/overlap we only tolerate the "already approved" condition.
			if !strings.Contains(err.Error(), "ERR_ALREADY_APPROVED") {
				return err
			}
		}
	}

	// NOTE: In Fabric, only the *last* SetEvent in a tx survives.
	// We keep KeyUpdateEvent last so listeners trigger on it consistently.
	return ctx.GetStub().SetEvent("KeyUpdateEvent", []byte("KeyUpdateEvent:"+keyID))
}

// ApproveKey records the invoker's approval for the given keyID.
// Removes 'approverID' param to prevent spoofing; derives from GetID().
func (s *SmartContract) ApproveKey(ctx contractapi.TransactionContextInterface, keyID string) error {
	invoker, err := s.requireRegistered(ctx)
	if err != nil {
		return err
	}

	// Load key
	raw, err := ctx.GetStub().GetState(keyID)
	if err != nil || len(raw) == 0 {
		return fmt.Errorf("ERR_KEY_NOT_FOUND: key not found")
	}
	var k PQCKey
	if err := json.Unmarshal(raw, &k); err != nil {
		return err
	}

	// Owner must be registered and cannot self-approve
	ok, err := s.isRegistered(ctx, k.Owner)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("ERR_OWNER_NOT_REGISTERED: owner controller is not registered")
	}
	if invoker == k.Owner {
		return fmt.Errorf("ERR_OWNER_CANNOT_APPROVE: key owner cannot approve their own key")
	}

	// Idempotency
	if k.Approved {
		return nil
	}
	if ok, err := hasApproval(ctx, keyID, invoker); err != nil {
		return err
	} else if ok {
		return fmt.Errorf("ERR_ALREADY_APPROVED: already approved")
	}

	// Write unique approval record (keeps MVCC off the main key)
	ack, err := approvalCompositeKey(ctx, keyID, invoker)
	if err != nil {
		return err
	}
	if err := ctx.GetStub().PutState(ack, []byte("1")); err != nil {
		return err
	}

	// Increment counter (single-key write → at worst MVCC, no phantom)
	cur, err := readApprovalCount(ctx, keyID)
	if err != nil {
		return err
	}
	newCnt := cur + 1
	if err := writeApprovalCount(ctx, keyID, newCnt); err != nil {
		return err
	}

	threshold, err := s.GetDynamicApprovalThreshold(ctx)
	if err != nil {
		return err
	}

	// If threshold reached, flip and emit KeyAccepted
	if newCnt >= threshold && !k.Approved {
		k.Approved = true
		k.ApprovedAt = time.Now().UTC().Format(time.RFC3339Nano)

		out, err := json.Marshal(&k)
		if err != nil {
			return fmt.Errorf("marshal updated key: %w", err)
		}
		if err := ctx.GetStub().PutState(keyID, out); err != nil {
			return err
		}
		ptr := "latestApprovedKey:" + k.Owner
		if err := ctx.GetStub().PutState(ptr, []byte(k.KeyID)); err != nil {
			return fmt.Errorf("failed to update latest approved pointer: %w", err)
		}

		// Use helper; pass empty slice to keep JSON schema stable (approvals: [])
		status := makeApprovalStatus(&k, threshold, newCnt, []string{})
		payload, _ := json.Marshal(status)
		return ctx.GetStub().SetEvent("KeyAccepted", payload)
	}

	// Otherwise emit per-approval status (same schema)
	status := makeApprovalStatus(&k, threshold, newCnt, []string{})
	payload, _ := json.Marshal(status)
	return ctx.GetStub().SetEvent("KeyApprovalAdded", payload)
}

// Get latest APPROVED key for a controller.
func (s *SmartContract) GetApprovedKeyByController(ctx contractapi.TransactionContextInterface,
	controllerID string) (*PQCKey, error) {
	ptr := "latestApprovedKey:" + controllerID
	idb, err := ctx.GetStub().GetState(ptr)
	if err != nil {
		return nil, fmt.Errorf("pointer read error: %w", err)
	}
	if len(idb) == 0 {
		return nil, fmt.Errorf("no approved key for controller")
	}

	raw, err := ctx.GetStub().GetState(string(idb))
	if err != nil || len(raw) == 0 {
		return nil, fmt.Errorf("ERR_KEY_NOT_FOUND: approved key not found")
	}

	var k PQCKey
	if err := json.Unmarshal(raw, &k); err != nil {
		return nil, err
	}
	if k.Owner != controllerID {
		return nil, fmt.Errorf("owner mismatch")
	}
	if !k.Approved {
		return nil, fmt.Errorf("pointer inconsistent: key not approved")
	}
	return &k, nil
}

// GetLatestSubmittedKey returns the most recently SUBMITTED key (may be pending).
func (s *SmartContract) GetLatestSubmittedKey(
	ctx contractapi.TransactionContextInterface,
	controllerID string,
) (*PQCKey, error) {
	ptr := "latestKey:" + controllerID
	idb, err := ctx.GetStub().GetState(ptr)
	if err != nil {
		return nil, fmt.Errorf("pointer read error: %w", err)
	}
	if len(idb) == 0 {
		return nil, fmt.Errorf("no key submitted by controller")
	}

	raw, err := ctx.GetStub().GetState(string(idb))
	if err != nil || len(raw) == 0 {
		return nil, fmt.Errorf("ERR_KEY_NOT_FOUND: submitted key not found")
	}

	var k PQCKey
	if err := json.Unmarshal(raw, &k); err != nil {
		return nil, err
	}
	if k.Owner != controllerID {
		return nil, fmt.Errorf("owner mismatch")
	}
	return &k, nil
}

// ListKeysByController returns all keys submitted by a controller.
// It reads the composite index "ctrl~key:(controllerID, timestamp) -> keyID",
// fetches each key, and optionally filters/ordering.
//
// Params:
//   - controllerID: exact string returned by GetID() when the key was submitted
//   - newestFirst:  if true, returns newest→oldest (by index timestamp)
//   - onlyApproved: if true, returns only Approved==true keys
func (s *SmartContract) ListKeysByController(
	ctx contractapi.TransactionContextInterface,
	controllerID string,
	newestFirst bool,
	onlyApproved bool,
) ([]PQCKey, error) {

	const idxName = "ctrl~key"

	iter, err := ctx.GetStub().GetStateByPartialCompositeKey(idxName, []string{controllerID})
	if err != nil {
		return nil, fmt.Errorf("index scan failed: %w", err)
	}
	defer iter.Close()

	var items []PQCKey
	for iter.HasNext() {
		kv, err := iter.Next()
		if err != nil {
			return nil, fmt.Errorf("index read error: %w", err)
		}

		// Value of the composite index entry is the keyID (as per your new design)
		keyID := string(kv.Value)
		if keyID == "" {
			// Defensive: skip malformed entries
			continue
		}

		raw, err := ctx.GetStub().GetState(keyID)
		if err != nil {
			return nil, fmt.Errorf("failed to read key %s: %w", keyID, err)
		}
		if len(raw) == 0 {
			// Key was deleted or never written; skip
			continue
		}

		var k PQCKey
		if err := json.Unmarshal(raw, &k); err != nil {
			return nil, fmt.Errorf("failed to parse key %s: %w", keyID, err)
		}
		if k.Owner != controllerID {
			// Extra safety: index mismatch; skip
			continue
		}
		if onlyApproved && !k.Approved {
			continue
		}
		items = append(items, k)
	}

	// Fabric’s composite key ordering is lexicographic by attributes;
	// with RFC3339 timestamps, that’s chronological (oldest→newest).
	// If caller wants newest first, reverse in-place.
	if newestFirst {
		for i, j := 0, len(items)-1; i < j; i, j = i+1, j-1 {
			items[i], items[j] = items[j], items[i]
		}
	}

	return items, nil
}

// ListKeyIDsByController returns only the keyIDs, optionally newest→oldest.
func (s *SmartContract) ListKeyIDsByController(
	ctx contractapi.TransactionContextInterface,
	controllerID string,
	newestFirst bool,
) ([]string, error) {

	const idxName = "ctrl~key"
	iter, err := ctx.GetStub().GetStateByPartialCompositeKey(idxName, []string{controllerID})
	if err != nil {
		return nil, fmt.Errorf("index scan failed: %w", err)
	}
	defer iter.Close()

	var ids []string
	for iter.HasNext() {
		kv, err := iter.Next()
		if err != nil {
			return nil, fmt.Errorf("index read error: %w", err)
		}
		id := string(kv.Value)
		if id != "" {
			ids = append(ids, id)
		}
	}
	if newestFirst {
		for i, j := 0, len(ids)-1; i < j; i, j = i+1, j-1 {
			ids[i], ids[j] = ids[j], ids[i]
		}
	}
	return ids, nil
}

// Helper for debuggin approvals
func (s *SmartContract) GetApprovalStatus(ctx contractapi.TransactionContextInterface, keyID string) (*ApprovalStatus, error) {
	raw, err := ctx.GetStub().GetState(keyID)
	if err != nil || len(raw) == 0 {
		return nil, fmt.Errorf("ERR_KEY_NOT_FOUND: key not found")
	}
	var k PQCKey
	if err := json.Unmarshal(raw, &k); err != nil {
		return nil, err
	}

	th, err := s.GetDynamicApprovalThreshold(ctx)
	if err != nil {
		return nil, err
	}

	cnt, ids, err := countApprovals(ctx, keyID, true)
	if err != nil {
		return nil, err
	}
	if ids == nil { // <-- ensure [] not null
		ids = []string{}
	}

	return &ApprovalStatus{
		KeyID:      k.KeyID,
		Owner:      k.Owner,
		Approved:   k.Approved,
		ApprovedAt: k.ApprovedAt, // "" if pending
		Approvals:  ids,          // now always [] when empty
		Count:      cnt,
		Threshold:  th,
		Version:    k.Version,
	}, nil
}

// VerifySignatureByController verifies a signature using the Dilithium key
// stored on-chain for `controllerID`.
func (s *SmartContract) VerifySignatureByController(
	ctx contractapi.TransactionContextInterface,
	controllerID string,
	messageB64 string,
	signatureB64 string,
) (bool, error) {

	pubB64, err := s.GetDilithiumPubKey(ctx, controllerID)
	if err != nil {
		return false, err
	}

	msg, err := base64.StdEncoding.DecodeString(messageB64)
	if err != nil {
		return false, fmt.Errorf("bad message: %v", err)
	}

	ok := VerifyPQCSignature(msg, signatureB64, pubB64)
	return ok, nil
}

// ================================
// Bootstrap (CCAAS)
// ================================

// Main function to start the Chaincode-as-a-Service
func main() {
	// Get environment variables for Chaincode ID and Address
	config := struct {
		CCID    string
		Address string
	}{
		CCID:    os.Getenv("CHAINCODE_ID"),
		Address: os.Getenv("CHAINCODE_SERVER_ADDRESS"),
	}

	// Create a new instance of the SmartContract
	chaincode, err := contractapi.NewChaincode(&SmartContract{})
	if err != nil {
		log.Panicf("Error creating chaincode: %s", err)
	}

	// Start the chaincode as a server
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
	// Check if chaincode is TLS enabled
	tlsDisabledStr := getEnvOrDefault("CHAINCODE_TLS_DISABLED", "true")
	key := getEnvOrDefault("CHAINCODE_TLS_KEY", "")
	cert := getEnvOrDefault("CHAINCODE_TLS_CERT", "")
	clientCACert := getEnvOrDefault("CHAINCODE_CLIENT_CA_CERT", "")

	// convert tlsDisabledStr to boolean
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
	// Did not request for the peer cert verification
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

// Note that the method returns default value if the string
// cannot be parsed!
func getBoolOrDefault(value string, defaultVal bool) bool {
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return defaultVal
	}
	return parsed
}
