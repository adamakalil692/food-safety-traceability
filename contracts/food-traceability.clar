;; Food Traceability Smart Contract
;; Tracks food products from origin to consumer, ensuring safety and provenance

;; Constants and error codes
(define-constant contract-owner tx-sender)
(define-constant err-unauthorized (err u100))
(define-constant err-not-found (err u101))
(define-constant err-invalid-input (err u102))
(define-constant err-duplicate (err u103))
(define-constant err-inactive (err u104))
(define-constant err-invalid-stage (err u105))

;; Data variables
(define-data-var product-counter uint u0)
(define-data-var event-counter uint u0)
(define-data-var facility-counter uint u0)

;; Stage constants
(define-constant stage-harvested "HARVESTED")
(define-constant stage-processed "PROCESSED")
(define-constant stage-packaged "PACKAGED")
(define-constant stage-shipped "SHIPPED")
(define-constant stage-received "RECEIVED")
(define-constant stage-recalled "RECALLED")

;; Role management
(define-map participants
  { who: principal }
  {
    role: (string-ascii 20),      ;; FARMER, PROCESSOR, DISTRIBUTOR, RETAILER, REGULATOR
    active: bool,
    added-at: uint
  }
)

;; Product registry
(define-map products
  { product-id: uint }
  {
    batch: (string-ascii 50),
    origin-farm: principal,
    current-owner: principal,
    harvest-date: uint,
    expiration-date: (optional uint),
    certification-hash: (optional (buff 32)),
    stage: (string-ascii 20),
    active: bool,
    created-at: uint
  }
)

;; Facility registry (processing plants, warehouses, stores)
(define-map facilities
  { facility-id: uint }
  {
    owner: principal,
    kind: (string-ascii 20),       ;; FARM, PLANT, WAREHOUSE, RETAIL
    location-hash: (buff 32),
    active: bool,
    added-at: uint
  }
)

;; Product custody and events log
(define-map product-events
  { event-id: uint }
  {
    product-id: uint,
    event-type: (string-ascii 20),  ;; HARVEST, PROCESS, SHIP, RECEIVE, QC, RECALL
    by: principal,
    facility-id: (optional uint),
    details-hash: (buff 32),
    temperature: (optional int),
    timestamp: uint
  }
)

;; Index: product -> events (simple counters for demo)
(define-map product-event-counters
  { product-id: uint }
  { last-event-id: uint }
)

;; Authorization helpers
(define-private (is-owner)
  (is-eq tx-sender contract-owner)
)

(define-private (has-role (role (string-ascii 20)))
  (match (map-get? participants { who: tx-sender })
    p (and (get active p) (is-eq (get role p) role))
    false
  )
)

(define-private (is-active-participant (p principal))
  (match (map-get? participants { who: p })
    rec (get active rec)
    false
  )
)

;; Participant management
(define-public (register-participant (who principal) (role (string-ascii 20)))
  (begin
    (asserts! (is-owner) err-unauthorized)
    (map-set participants { who: who } { role: role, active: true, added-at: u1 })
    (ok true)
  )
)

(define-public (set-participant-active (who principal) (active bool))
  (begin
    (asserts! (is-owner) err-unauthorized)
    (match (map-get? participants { who: who })
      rec (begin
            (map-set participants { who: who } (merge rec { active: active }))
            (ok active)
          )
      err-not-found
    )
  )
)

;; Facility management
(define-public (register-facility
  (owner principal)
  (kind (string-ascii 20))
  (location-hash (buff 32))
)
  (begin
    (asserts! (or (is-owner) (is-eq owner tx-sender)) err-unauthorized)
    (asserts! (is-active-participant owner) err-unauthorized)
    (let ((fid (+ (var-get facility-counter) u1)))
      (map-set facilities { facility-id: fid }
        { owner: owner, kind: kind, location-hash: location-hash, active: true, added-at: u1 })
      (var-set facility-counter fid)
      (ok fid)
    )
  )
)

(define-public (set-facility-active (facility-id uint) (active bool))
  (begin
    (match (map-get? facilities { facility-id: facility-id })
      f (begin
          (asserts! (or (is-owner) (is-eq (get owner f) tx-sender)) err-unauthorized)
          (map-set facilities { facility-id: facility-id } (merge f { active: active }))
          (ok active)
        )
      err-not-found
    )
  )
)

;; Product lifecycle
(define-public (create-product
  (batch (string-ascii 50))
  (harvest-date uint)
  (expiration-date (optional uint))
  (certification-hash (optional (buff 32)))
)
  (begin
    (asserts! (has-role "FARMER") err-unauthorized)
    (let ((pid (+ (var-get product-counter) u1)))
      (map-set products { product-id: pid }
        {
          batch: batch,
          origin-farm: tx-sender,
          current-owner: tx-sender,
          harvest-date: harvest-date,
          expiration-date: expiration-date,
          certification-hash: certification-hash,
          stage: stage-harvested,
          active: true,
          created-at: u1
        }
      )
      (var-set product-counter pid)
      (ok pid)
    )
  )
)

(define-private (append-event
  (product-id uint)
  (event-type (string-ascii 20))
  (facility (optional uint))
  (details-hash (buff 32))
  (temperature (optional int))
)
  (let ((eid (+ (var-get event-counter) u1)))
    (begin
      (map-set product-events { event-id: eid }
        {
          product-id: product-id,
          event-type: event-type,
          by: tx-sender,
          facility-id: facility,
          details-hash: details-hash,
          temperature: temperature,
          timestamp: u1
        }
      )
      (var-set event-counter eid)
      (match (map-get? product-event-counters { product-id: product-id })
        c (map-set product-event-counters { product-id: product-id } (merge c { last-event-id: eid }))
        false
      )
      (ok eid)
    )
  )
)

(define-public (process-product
  (product-id uint)
  (facility-id uint)
  (details-hash (buff 32))
)
  (begin
    (asserts! (has-role "PROCESSOR") err-unauthorized)
    (match (map-get? products { product-id: product-id })
      p (begin
          (asserts! (get active p) err-inactive)
          (asserts! (is-eq (get stage p) stage-harvested) err-invalid-stage)
          (map-set products { product-id: product-id }
            (merge p { stage: stage-processed, current-owner: tx-sender }))
          (append-event product-id "PROCESS" (some facility-id) details-hash none)
        )
      err-not-found
    )
  )
)

(define-public (package-product
  (product-id uint)
  (facility-id uint)
  (details-hash (buff 32))
)
  (begin
    (asserts! (has-role "PROCESSOR") err-unauthorized)
    (match (map-get? products { product-id: product-id })
      p (begin
          (asserts! (get active p) err-inactive)
          (asserts! (is-eq (get stage p) stage-processed) err-invalid-stage)
          (map-set products { product-id: product-id }
            (merge p { stage: stage-packaged, current-owner: tx-sender }))
          (append-event product-id "PACKAGE" (some facility-id) details-hash none)
        )
      err-not-found
    )
  )
)

(define-public (ship-product
  (product-id uint)
  (from-facility uint)
  (to-facility uint)
  (details-hash (buff 32))
  (temperature (optional int))
)
  (begin
    (asserts! (has-role "DISTRIBUTOR") err-unauthorized)
    (match (map-get? products { product-id: product-id })
      p (begin
          (asserts! (get active p) err-inactive)
          (asserts! (or (is-eq (get stage p) stage-packaged)
                        (is-eq (get stage p) stage-received)) err-invalid-stage)
          (map-set products { product-id: product-id }
            (merge p { stage: stage-shipped, current-owner: tx-sender }))
          (unwrap! (append-event product-id "SHIP" (some from-facility) details-hash temperature) err-invalid-input)
          (append-event product-id "DESTINATION" (some to-facility) details-hash none)
        )
      err-not-found
    )
  )
)

(define-public (receive-product
  (product-id uint)
  (facility-id uint)
  (details-hash (buff 32))
)
  (begin
    (asserts! (or (has-role "DISTRIBUTOR") (has-role "RETAILER")) err-unauthorized)
    (match (map-get? products { product-id: product-id })
      p (begin
          (asserts! (get active p) err-inactive)
          (asserts! (is-eq (get stage p) stage-shipped) err-invalid-stage)
          (map-set products { product-id: product-id }
            (merge p { stage: stage-received, current-owner: tx-sender }))
          (append-event product-id "RECEIVE" (some facility-id) details-hash none)
        )
      err-not-found
    )
  )
)

;; Quality control and recall
(define-public (record-qc
  (product-id uint)
  (facility-id uint)
  (details-hash (buff 32))
  (temperature (optional int))
)
  (begin
    (asserts! (or (has-role "PROCESSOR") (has-role "DISTRIBUTOR") (has-role "RETAILER")) err-unauthorized)
    (match (map-get? products { product-id: product-id })
      p (begin
          (asserts! (get active p) err-inactive)
          (append-event product-id "QC" (some facility-id) details-hash temperature)
        )
      err-not-found
    )
  )
)

(define-public (recall-product
  (product-id uint)
  (reason-hash (buff 32))
)
  (begin
    (asserts! (has-role "REGULATOR") err-unauthorized)
    (match (map-get? products { product-id: product-id })
      p (begin
          (asserts! (get active p) err-inactive)
          (map-set products { product-id: product-id }
            (merge p { stage: stage-recalled, active: false }))
          (append-event product-id "RECALL" none reason-hash none)
        )
      err-not-found
    )
  )
)

;; Read-only queries
(define-read-only (get-product (product-id uint))
  (map-get? products { product-id: product-id })
)

(define-read-only (get-participant (who principal))
  (map-get? participants { who: who })
)

(define-read-only (get-facility (facility-id uint))
  (map-get? facilities { facility-id: facility-id })
)

(define-read-only (get-event (event-id uint))
  (map-get? product-events { event-id: event-id })
)

(define-read-only (get-latest-event-id (product-id uint))
  (match (map-get? product-event-counters { product-id: product-id })
    c (some (get last-event-id c))
    none
  )
)

(define-read-only (get-product-counter)
  (var-get product-counter)
)

(define-read-only (get-event-counter)
  (var-get event-counter)
)

(define-read-only (get-facility-counter)
  (var-get facility-counter)
)

