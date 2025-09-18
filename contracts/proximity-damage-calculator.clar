;; Proximity Damage Calculator
;; Automated damage estimation based on distance from epicenter and magnitude

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_INVALID_COORDINATES (err u201))
(define-constant ERR_INVALID_MAGNITUDE (err u202))
(define-constant ERR_PROPERTY_NOT_FOUND (err u203))
(define-constant ERR_ASSESSMENT_NOT_FOUND (err u204))
(define-constant ERR_INVALID_PROPERTY_VALUE (err u205))
(define-constant ERR_CALCULATION_ERROR (err u206))

;; Damage calculation constants
(define-constant EARTH_RADIUS u6371000) ;; Earth's radius in meters
(define-constant PI u314159) ;; Pi scaled by 100000
(define-constant MAX_DAMAGE_DISTANCE u50000) ;; 50km max distance for damage
(define-constant MIN_MAGNITUDE_DAMAGE u500) ;; Magnitude 5.0 minimum for damage
(define-constant DAMAGE_SCALE_FACTOR u10000) ;; Scaling factor for calculations

;; Data Variables
(define-data-var next-assessment-id uint u1)
(define-data-var authorized-assessors (list 20 principal) (list))
(define-data-var total-assessments uint u0)
(define-data-var damage-calculation-enabled bool true)

;; Data Maps
(define-map property-locations
  { property-id: uint }
  {
    latitude: int, ;; Scaled by 1000000
    longitude: int, ;; Scaled by 1000000
    property-value: uint, ;; In STX microtokens
    property-type: (string-ascii 50),
    owner: principal,
    registered-at: uint,
    active: bool
  }
)

(define-map damage-assessments
  { assessment-id: uint }
  {
    property-id: uint,
    earthquake-id: uint,
    epicenter-latitude: int,
    epicenter-longitude: int,
    magnitude: uint,
    distance-km: uint, ;; Distance in kilometers
    damage-percentage: uint, ;; Percentage scaled by 100 (0-10000)
    estimated-damage-value: uint,
    assessed-at: uint,
    assessor: principal,
    verified: bool
  }
)

(define-map assessor-permissions
  { assessor: principal }
  { authorized: bool, added-at: uint }
)

(define-map property-damage-history
  { property-id: uint, earthquake-id: uint }
  { assessment-id: uint }
)

(define-map magnitude-damage-multipliers
  { magnitude-range: uint } ;; Magnitude ranges: 5=5.0-5.9, 6=6.0-6.9, etc.
  { base-damage-percent: uint, distance-decay-rate: uint }
)

;; Initialize damage multipliers
(map-set magnitude-damage-multipliers { magnitude-range: u5 } { base-damage-percent: u1000, distance-decay-rate: u200 })
(map-set magnitude-damage-multipliers { magnitude-range: u6 } { base-damage-percent: u2500, distance-decay-rate: u150 })
(map-set magnitude-damage-multipliers { magnitude-range: u7 } { base-damage-percent: u5000, distance-decay-rate: u100 })
(map-set magnitude-damage-multipliers { magnitude-range: u8 } { base-damage-percent: u7500, distance-decay-rate: u75 })
(map-set magnitude-damage-multipliers { magnitude-range: u9 } { base-damage-percent: u9000, distance-decay-rate: u50 })

;; Read-only functions
(define-read-only (get-property-location (property-id uint))
  (map-get? property-locations { property-id: property-id })
)

(define-read-only (get-damage-assessment (assessment-id uint))
  (map-get? damage-assessments { assessment-id: assessment-id })
)

(define-read-only (get-property-damage-for-earthquake (property-id uint) (earthquake-id uint))
  (match (map-get? property-damage-history { property-id: property-id, earthquake-id: earthquake-id })
    history-entry (map-get? damage-assessments { assessment-id: (get assessment-id history-entry) })
    none
  )
)

(define-read-only (calculate-distance-km (lat1 int) (lon1 int) (lat2 int) (lon2 int))
  ;; Simplified distance calculation using Manhattan distance approximation
  (let (
    (dlat (int-abs (- lat2 lat1)))
    (dlon (int-abs (- lon2 lon1)))
    ;; Approximate distance calculation (simplified for gas efficiency)
    (lat-diff-km (/ (* (to-uint dlat) u111) u1000000)) ;; ~111km per degree latitude
    (lon-diff-km (/ (* (to-uint dlon) u85) u1000000))  ;; ~85km per degree longitude (average)
  )
    ;; Use Manhattan distance as approximation (simpler than Euclidean)
    (+ lat-diff-km lon-diff-km)
  )
)

(define-read-only (calculate-damage-percentage (magnitude uint) (distance-km uint))
  (if (> distance-km MAX_DAMAGE_DISTANCE)
    u0 ;; No damage beyond max distance
    (let (
      (mag-range (/ magnitude u100)) ;; Get magnitude integer part
      (multiplier-data (default-to 
        { base-damage-percent: u500, distance-decay-rate: u300 }
        (map-get? magnitude-damage-multipliers { magnitude-range: mag-range })))
      (base-damage (get base-damage-percent multiplier-data))
      (decay-rate (get distance-decay-rate multiplier-data))
      ;; Apply distance decay: damage = base * e^(-decay * distance)
      ;; Simplified as: damage = base * (10000 - decay * distance) / 10000
      (distance-factor (if (> (* decay-rate distance-km) u10000)
        u0
        (- u10000 (* decay-rate distance-km))))
    )
      (/ (* base-damage distance-factor) u10000)
    )
  )
)

(define-read-only (estimate-property-damage (property-value uint) (damage-percentage uint))
  (/ (* property-value damage-percentage) u10000)
)

(define-read-only (is-authorized-assessor (assessor principal))
  (match (map-get? assessor-permissions { assessor: assessor })
    permission-data (get authorized permission-data)
    false
  )
)

(define-read-only (get-total-assessments)
  (var-get total-assessments)
)

(define-read-only (is-calculation-enabled)
  (var-get damage-calculation-enabled)
)

;; Private functions
(define-private (validate-coordinates (lat int) (lon int))
  (and
    (>= lat -90000000)
    (<= lat 90000000)
    (>= lon -180000000)
    (<= lon 180000000)
  )
)

(define-private (remove-assessor-from-list (assessor principal))
  (not (is-eq assessor tx-sender))
)

(define-private (int-abs (n int))
  (if (>= n 0) n (- 0 n))
)

;; Public functions
(define-public (add-authorized-assessor (assessor principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set assessor-permissions
      { assessor: assessor }
      { authorized: true, added-at: stacks-block-height }
    )
    (var-set authorized-assessors
      (unwrap-panic (as-max-len? (append (var-get authorized-assessors) assessor) u20))
    )
    (ok true)
  )
)

(define-public (remove-authorized-assessor (assessor principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set assessor-permissions
      { assessor: assessor }
      { authorized: false, added-at: stacks-block-height }
    )
    (var-set authorized-assessors
      (filter remove-assessor-from-list (var-get authorized-assessors))
    )
    (ok true)
  )
)

(define-public (register-property
  (property-id uint)
  (latitude int)
  (longitude int)
  (property-value uint)
  (property-type (string-ascii 50))
)
  (begin
    (asserts! (validate-coordinates latitude longitude) ERR_INVALID_COORDINATES)
    (asserts! (> property-value u0) ERR_INVALID_PROPERTY_VALUE)
    (asserts! (is-none (map-get? property-locations { property-id: property-id })) ERR_PROPERTY_NOT_FOUND)
    
    (map-set property-locations
      { property-id: property-id }
      {
        latitude: latitude,
        longitude: longitude,
        property-value: property-value,
        property-type: property-type,
        owner: tx-sender,
        registered-at: stacks-block-height,
        active: true
      }
    )
    (ok true)
  )
)

(define-public (assess-earthquake-damage
  (property-id uint)
  (earthquake-id uint)
  (epicenter-latitude int)
  (epicenter-longitude int)
  (magnitude uint)
)
  (begin
    (asserts! (is-authorized-assessor tx-sender) ERR_UNAUTHORIZED)
    (asserts! (var-get damage-calculation-enabled) ERR_CALCULATION_ERROR)
    (asserts! (>= magnitude MIN_MAGNITUDE_DAMAGE) ERR_INVALID_MAGNITUDE)
    
    (let (
      (property-data (unwrap! (map-get? property-locations { property-id: property-id }) ERR_PROPERTY_NOT_FOUND))
      (assessment-id (var-get next-assessment-id))
      (distance (calculate-distance-km 
        (get latitude property-data)
        (get longitude property-data)
        epicenter-latitude
        epicenter-longitude))
      (damage-percent (calculate-damage-percentage magnitude distance))
      (damage-value (estimate-property-damage (get property-value property-data) damage-percent))
    )
      ;; Store assessment
      (map-set damage-assessments
        { assessment-id: assessment-id }
        {
          property-id: property-id,
          earthquake-id: earthquake-id,
          epicenter-latitude: epicenter-latitude,
          epicenter-longitude: epicenter-longitude,
          magnitude: magnitude,
          distance-km: distance,
          damage-percentage: damage-percent,
          estimated-damage-value: damage-value,
          assessed-at: stacks-block-height,
          assessor: tx-sender,
          verified: false
        }
      )
      
      ;; Create history entry
      (map-set property-damage-history
        { property-id: property-id, earthquake-id: earthquake-id }
        { assessment-id: assessment-id }
      )
      
      ;; Update counters
      (var-set next-assessment-id (+ assessment-id u1))
      (var-set total-assessments (+ (var-get total-assessments) u1))
      
      (ok {
        assessment-id: assessment-id,
        distance-km: distance,
        damage-percentage: damage-percent,
        estimated-damage-value: damage-value
      })
    )
  )
)

(define-public (verify-damage-assessment (assessment-id uint))
  (begin
    (asserts! (is-authorized-assessor tx-sender) ERR_UNAUTHORIZED)
    (let (
      (assessment-data (unwrap! (map-get? damage-assessments { assessment-id: assessment-id }) ERR_ASSESSMENT_NOT_FOUND))
    )
      (map-set damage-assessments
        { assessment-id: assessment-id }
        (merge assessment-data { verified: true })
      )
      (ok true)
    )
  )
)

(define-public (update-property-value (property-id uint) (new-value uint))
  (begin
    (let (
      (property-data (unwrap! (map-get? property-locations { property-id: property-id }) ERR_PROPERTY_NOT_FOUND))
    )
      (asserts! (is-eq tx-sender (get owner property-data)) ERR_UNAUTHORIZED)
      (asserts! (> new-value u0) ERR_INVALID_PROPERTY_VALUE)
      
      (map-set property-locations
        { property-id: property-id }
        (merge property-data { property-value: new-value })
      )
      (ok true)
    )
  )
)

(define-public (set-calculation-enabled (enabled bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set damage-calculation-enabled enabled)
    (ok true)
  )
)

(define-public (update-damage-multiplier (magnitude-range uint) (base-damage uint) (decay-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set magnitude-damage-multipliers
      { magnitude-range: magnitude-range }
      { base-damage-percent: base-damage, distance-decay-rate: decay-rate }
    )
    (ok true)
  )
)

