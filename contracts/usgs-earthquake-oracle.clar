;; USGS Earthquake Oracle
;; Real-time earthquake data integration from USGS and global seismic networks

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_EARTHQUAKE_DATA (err u101))
(define-constant ERR_EARTHQUAKE_NOT_FOUND (err u102))
(define-constant ERR_DUPLICATE_EARTHQUAKE (err u103))
(define-constant ERR_INVALID_MAGNITUDE (err u104))
(define-constant ERR_INVALID_COORDINATES (err u105))
(define-constant MIN_MAGNITUDE u100) ;; 1.0 magnitude (scaled by 100)
(define-constant MAX_MAGNITUDE u1000) ;; 10.0 magnitude (scaled by 100)
(define-constant MAX_DEPTH u70000) ;; 700km depth in meters

;; Data Variables
(define-data-var next-earthquake-id uint u1)
(define-data-var oracle-operators (list 50 principal) (list))
(define-data-var total-earthquakes uint u0)

;; Data Maps
(define-map earthquakes
  { earthquake-id: uint }
  {
    usgs-id: (string-ascii 50),
    magnitude: uint, ;; Scaled by 100 (e.g., 650 = 6.5)
    latitude: int, ;; Scaled by 1000000 (e.g., 37749000 = 37.749)
    longitude: int, ;; Scaled by 1000000 (e.g., -122419000 = -122.419)
    depth: uint, ;; Depth in meters
    timestamp: uint,
    location: (string-ascii 100),
    verified: bool,
    operator: principal
  }
)

(define-map earthquake-by-usgs-id
  { usgs-id: (string-ascii 50) }
  { earthquake-id: uint }
)

(define-map operator-permissions
  { operator: principal }
  { authorized: bool, added-at: uint }
)

(define-map recent-earthquakes-by-region
  { region-lat: int, region-lon: int } ;; Coordinates rounded to nearest degree
  { recent-count: uint, last-updated: uint }
)

;; Read-only functions
(define-read-only (get-earthquake (earthquake-id uint))
  (map-get? earthquakes { earthquake-id: earthquake-id })
)

(define-read-only (get-earthquake-by-usgs-id (usgs-id (string-ascii 50)))
  (match (map-get? earthquake-by-usgs-id { usgs-id: usgs-id })
    earthquake-info (map-get? earthquakes { earthquake-id: (get earthquake-id earthquake-info) })
    none
  )
)

(define-read-only (get-recent-earthquakes-count (lat int) (lon int))
  (match (map-get? recent-earthquakes-by-region { region-lat: lat, region-lon: lon })
    region-data (get recent-count region-data)
    u0
  )
)

(define-read-only (get-total-earthquakes)
  (var-get total-earthquakes)
)

(define-read-only (get-next-earthquake-id)
  (var-get next-earthquake-id)
)

(define-read-only (is-authorized-operator (operator principal))
  (match (map-get? operator-permissions { operator: operator })
    permission-data (get authorized permission-data)
    false
  )
)

(define-read-only (get-authorized-operators)
  (var-get oracle-operators)
)

;; Private functions
(define-private (validate-earthquake-data (magnitude uint) (latitude int) (longitude int) (depth uint))
  (and
    (>= magnitude MIN_MAGNITUDE)
    (<= magnitude MAX_MAGNITUDE)
    (>= latitude -90000000)
    (<= latitude 90000000)
    (>= longitude -180000000)
    (<= longitude 180000000)
    (<= depth MAX_DEPTH)
  )
)

(define-private (calculate-region-coordinates (lat int) (lon int))
  { 
    region-lat: (/ lat 1000000), ;; Round to nearest degree
    region-lon: (/ lon 1000000)  ;; Round to nearest degree
  }
)

(define-private (update-regional-statistics (lat int) (lon int))
  (let (
    (region-coords (calculate-region-coordinates lat lon))
    (current-data (default-to { recent-count: u0, last-updated: u0 }
      (map-get? recent-earthquakes-by-region region-coords)))
  )
    (map-set recent-earthquakes-by-region
      region-coords
      {
        recent-count: (+ (get recent-count current-data) u1),
        last-updated: stacks-block-height
      }
    )
    true
  )
)

(define-private (remove-operator-from-list (operator principal))
  (not (is-eq operator tx-sender))
)

(define-private (filter-earthquakes-by-magnitude (min-mag uint) (max-mag uint))
  ;; This is a simplified implementation - in practice, you'd iterate through earthquakes
  ;; For demonstration, returning empty list
  (list)
)

;; Public functions
(define-public (add-authorized-operator (operator principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set operator-permissions 
      { operator: operator }
      { authorized: true, added-at: stacks-block-height }
    )
    (var-set oracle-operators 
      (unwrap-panic (as-max-len? (append (var-get oracle-operators) operator) u50))
    )
    (ok true)
  )
)

(define-public (remove-authorized-operator (operator principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set operator-permissions
      { operator: operator }
      { authorized: false, added-at: stacks-block-height }
    )
    (var-set oracle-operators
      (filter remove-operator-from-list (var-get oracle-operators))
    )
    (ok true)
  )
)

(define-public (submit-earthquake-data 
  (usgs-id (string-ascii 50))
  (magnitude uint)
  (latitude int)
  (longitude int)
  (depth uint)
  (location (string-ascii 100))
)
  (begin
    (asserts! (is-authorized-operator tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-none (map-get? earthquake-by-usgs-id { usgs-id: usgs-id })) ERR_DUPLICATE_EARTHQUAKE)
    (asserts! (validate-earthquake-data magnitude latitude longitude depth) ERR_INVALID_EARTHQUAKE_DATA)
    
    (let (
      (earthquake-id (var-get next-earthquake-id))
    )
      ;; Store earthquake data
      (map-set earthquakes
        { earthquake-id: earthquake-id }
        {
          usgs-id: usgs-id,
          magnitude: magnitude,
          latitude: latitude,
          longitude: longitude,
          depth: depth,
          timestamp: stacks-block-height,
          location: location,
          verified: false,
          operator: tx-sender
        }
      )
      
      ;; Create USGS ID mapping
      (map-set earthquake-by-usgs-id
        { usgs-id: usgs-id }
        { earthquake-id: earthquake-id }
      )
      
      ;; Update statistics
      (update-regional-statistics latitude longitude)
      
      ;; Update counters
      (var-set next-earthquake-id (+ earthquake-id u1))
      (var-set total-earthquakes (+ (var-get total-earthquakes) u1))
      
      (ok earthquake-id)
    )
  )
)

(define-public (verify-earthquake-data (earthquake-id uint))
  (begin
    (asserts! (is-authorized-operator tx-sender) ERR_UNAUTHORIZED)
    (let (
      (earthquake-data (unwrap! (map-get? earthquakes { earthquake-id: earthquake-id }) ERR_EARTHQUAKE_NOT_FOUND))
    )
      (map-set earthquakes
        { earthquake-id: earthquake-id }
        (merge earthquake-data { verified: true })
      )
      (ok true)
    )
  )
)

(define-public (get-earthquakes-in-magnitude-range (min-magnitude uint) (max-magnitude uint))
  (begin
    (asserts! (<= min-magnitude max-magnitude) ERR_INVALID_MAGNITUDE)
    (ok (filter-earthquakes-by-magnitude min-magnitude max-magnitude))
  )
)

(define-public (update-earthquake-verification-status (earthquake-id uint) (verified bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (let (
      (earthquake-data (unwrap! (map-get? earthquakes { earthquake-id: earthquake-id }) ERR_EARTHQUAKE_NOT_FOUND))
    )
      (map-set earthquakes
        { earthquake-id: earthquake-id }
        (merge earthquake-data { verified: verified })
      )
      (ok true)
    )
  )
)

