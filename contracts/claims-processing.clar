;; Claims Processing Contract
;; Handles professional error and omission claims

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-NOT-FOUND (err u301))
(define-constant ERR-INVALID-INPUT (err u302))
(define-constant ERR-CLAIM-ALREADY-PROCESSED (err u303))
(define-constant ERR-INSUFFICIENT-COVERAGE (err u304))

;; Claim Status Constants
(define-constant STATUS-SUBMITTED u1)
(define-constant STATUS-UNDER-REVIEW u2)
(define-constant STATUS-APPROVED u3)
(define-constant STATUS-DENIED u4)
(define-constant STATUS-PAID u5)

;; Data Variables
(define-data-var next-claim-id uint u1)
(define-data-var claims-fund uint u1000000)

;; Data Maps
(define-map claims
  { claim-id: uint }
  {
    claimant: principal,
    freelancer: principal,
    claim-amount: uint,
    description: (string-ascii 500),
    incident-date: uint,
    submission-date: uint,
    status: uint,
    reviewer: (optional principal),
    settlement-amount: uint,
    payment-date: (optional uint),
    evidence-hash: (optional (buff 32))
  }
)

(define-map policy-coverage
  { freelancer: principal }
  {
    coverage-limit: uint,
    deductible: uint,
    premium-paid: uint,
    policy-start: uint,
    policy-end: uint,
    active: bool
  }
)

(define-map claim-evidence
  { claim-id: uint, evidence-id: uint }
  {
    evidence-type: (string-ascii 50),
    evidence-hash: (buff 32),
    submitted-by: principal,
    timestamp: uint
  }
)

;; Public Functions

;; Submit a claim
(define-public (submit-claim
  (freelancer principal)
  (claim-amount uint)
  (description (string-ascii 500))
  (incident-date uint)
  (evidence-hash (optional (buff 32)))
)
  (let
    (
      (claim-id (var-get next-claim-id))
      (policy (unwrap! (map-get? policy-coverage { freelancer: freelancer }) ERR-NOT-FOUND))
    )
    (asserts! (> claim-amount u0) ERR-INVALID-INPUT)
    (asserts! (> (len description) u0) ERR-INVALID-INPUT)
    (asserts! (get active policy) ERR-NOT-AUTHORIZED)
    (asserts! (<= claim-amount (get coverage-limit policy)) ERR-INSUFFICIENT-COVERAGE)
    (asserts! (<= incident-date block-height) ERR-INVALID-INPUT)
    (asserts! (>= incident-date (get policy-start policy)) ERR-INVALID-INPUT)
    (asserts! (<= incident-date (get policy-end policy)) ERR-INVALID-INPUT)

    (map-set claims
      { claim-id: claim-id }
      {
        claimant: tx-sender,
        freelancer: freelancer,
        claim-amount: claim-amount,
        description: description,
        incident-date: incident-date,
        submission-date: block-height,
        status: STATUS-SUBMITTED,
        reviewer: none,
        settlement-amount: u0,
        payment-date: none,
        evidence-hash: evidence-hash
      }
    )

    (var-set next-claim-id (+ claim-id u1))
    (ok claim-id)
  )
)

;; Review claim (admin only)
(define-public (review-claim (claim-id uint) (new-status uint) (settlement-amount uint))
  (let
    (
      (claim-data (unwrap! (map-get? claims { claim-id: claim-id }) ERR-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status claim-data) STATUS-SUBMITTED) ERR-CLAIM-ALREADY-PROCESSED)
    (asserts! (or (is-eq new-status STATUS-APPROVED) (is-eq new-status STATUS-DENIED)) ERR-INVALID-INPUT)

    (if (is-eq new-status STATUS-APPROVED)
      (begin
        (asserts! (> settlement-amount u0) ERR-INVALID-INPUT)
        (asserts! (<= settlement-amount (get claim-amount claim-data)) ERR-INVALID-INPUT)
        (map-set claims
          { claim-id: claim-id }
          (merge claim-data
            {
              status: STATUS-APPROVED,
              reviewer: (some tx-sender),
              settlement-amount: settlement-amount
            }
          )
        )
      )
      (map-set claims
        { claim-id: claim-id }
        (merge claim-data
          {
            status: STATUS-DENIED,
            reviewer: (some tx-sender)
          }
        )
      )
    )
    (ok true)
  )
)

;; Process payment for approved claim
(define-public (process-payment (claim-id uint))
  (let
    (
      (claim-data (unwrap! (map-get? claims { claim-id: claim-id }) ERR-NOT-FOUND))
      (policy (unwrap! (map-get? policy-coverage { freelancer: (get freelancer claim-data) }) ERR-NOT-FOUND))
      (net-payment (- (get settlement-amount claim-data) (get deductible policy)))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status claim-data) STATUS-APPROVED) ERR-INVALID-INPUT)
    (asserts! (>= (var-get claims-fund) net-payment) ERR-INSUFFICIENT-COVERAGE)

    (var-set claims-fund (- (var-get claims-fund) net-payment))

    (map-set claims
      { claim-id: claim-id }
      (merge claim-data
        {
          status: STATUS-PAID,
          payment-date: (some block-height)
        }
      )
    )

    (ok net-payment)
  )
)

;; Add policy coverage
(define-public (add-policy-coverage
  (freelancer principal)
  (coverage-limit uint)
  (deductible uint)
  (premium-amount uint)
  (policy-duration uint)
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> coverage-limit u0) ERR-INVALID-INPUT)
    (asserts! (> premium-amount u0) ERR-INVALID-INPUT)
    (asserts! (< deductible coverage-limit) ERR-INVALID-INPUT)

    (map-set policy-coverage
      { freelancer: freelancer }
      {
        coverage-limit: coverage-limit,
        deductible: deductible,
        premium-paid: premium-amount,
        policy-start: block-height,
        policy-end: (+ block-height policy-duration),
        active: true
      }
    )
    (ok true)
  )
)

;; Add evidence to claim
(define-public (add-claim-evidence
  (claim-id uint)
  (evidence-id uint)
  (evidence-type (string-ascii 50))
  (evidence-hash (buff 32))
)
  (let
    (
      (claim-data (unwrap! (map-get? claims { claim-id: claim-id }) ERR-NOT-FOUND))
    )
    (asserts! (or (is-eq tx-sender (get claimant claim-data)) (is-eq tx-sender (get freelancer claim-data))) ERR-NOT-AUTHORIZED)
    (asserts! (> (len evidence-type) u0) ERR-INVALID-INPUT)

    (map-set claim-evidence
      { claim-id: claim-id, evidence-id: evidence-id }
      {
        evidence-type: evidence-type,
        evidence-hash: evidence-hash,
        submitted-by: tx-sender,
        timestamp: block-height
      }
    )
    (ok true)
  )
)

;; Read-only Functions

;; Get claim details
(define-read-only (get-claim (claim-id uint))
  (map-get? claims { claim-id: claim-id })
)

;; Get policy coverage
(define-read-only (get-policy-coverage (freelancer principal))
  (map-get? policy-coverage { freelancer: freelancer })
)

;; Get claim evidence
(define-read-only (get-claim-evidence (claim-id uint) (evidence-id uint))
  (map-get? claim-evidence { claim-id: claim-id, evidence-id: evidence-id })
)

;; Get claims fund balance
(define-read-only (get-claims-fund-balance)
  (var-get claims-fund)
)

;; Check if claim is valid for processing
(define-read-only (is-claim-processable (claim-id uint))
  (match (map-get? claims { claim-id: claim-id })
    claim-data (and
      (is-eq (get status claim-data) STATUS-APPROVED)
      (>= (var-get claims-fund) (get settlement-amount claim-data))
    )
    false
  )
)
