;; Rapid Payout Processor
;; Instant claim processing within hours of seismic event detection

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u300))
(define-constant ERR_POLICY_NOT_FOUND (err u301))
(define-constant ERR_CLAIM_NOT_FOUND (err u302))
(define-constant ERR_INSUFFICIENT_FUNDS (err u303))
(define-constant ERR_CLAIM_ALREADY_PROCESSED (err u304))
(define-constant ERR_CLAIM_EXPIRED (err u305))
(define-constant ERR_INVALID_POLICY_DATA (err u306))
(define-constant ERR_PAYOUT_DISABLED (err u307))
(define-constant ERR_MINIMUM_DAMAGE_NOT_MET (err u308))
(define-constant ERR_INVALID_PREMIUM (err u309))
(define-constant ERR_POLICY_INACTIVE (err u310))

;; Policy and payout constants
(define-constant MIN_POLICY_AMOUNT u1000000) ;; 1 STX minimum
(define-constant MAX_POLICY_AMOUNT u1000000000000) ;; 1M STX maximum
(define-constant MIN_DAMAGE_THRESHOLD u500) ;; 5% minimum damage for payout
(define-constant CLAIM_EXPIRY_BLOCKS u52560) ;; ~1 year in blocks
(define-constant PREMIUM_RATE u100) ;; 1% annual premium rate

;; Data Variables
(define-data-var next-policy-id uint u1)
(define-data-var next-claim-id uint u1)
(define-data-var total-policies uint u0)
(define-data-var total-claims uint u0)
(define-data-var total-payouts uint u0)
(define-data-var insurance-pool-balance uint u0)
(define-data-var payout-enabled bool true)
(define-data-var authorized-processors (list 10 principal) (list))

;; Data Maps
(define-map insurance-policies
  { policy-id: uint }
  {
    policyholder: principal,
    property-id: uint,
    coverage-amount: uint,
    premium-paid: uint,
    policy-start-block: uint,
    policy-end-block: uint,
    active: bool,
    total-claims: uint,
    total-payouts-received: uint
  }
)

(define-map policy-by-property
  { property-id: uint }
  { policy-id: uint }
)

(define-map claims
  { claim-id: uint }
  {
    policy-id: uint,
    earthquake-id: uint,
    assessment-id: uint,
    claim-amount: uint,
    damage-percentage: uint,
    submitted-at: uint,
    processed-at: uint,
    status: (string-ascii 20), ;; "pending", "approved", "denied", "paid"
    processor: (optional principal),
    payout-transaction: (optional uint)
  }
)

(define-map policy-claims-history
  { policy-id: uint, earthquake-id: uint }
  { claim-id: uint }
)

(define-map processor-permissions
  { processor: principal }
  { authorized: bool, added-at: uint }
)

(define-map premium-payments
  { policy-id: uint, payment-block: uint }
  { amount: uint, paid-by: principal }
)

(define-map insurance-pool-contributions
  { contributor: principal }
  { total-contributed: uint, contribution-blocks: (list 100 uint) }
)

;; Read-only functions
(define-read-only (get-policy (policy-id uint))
  (map-get? insurance-policies { policy-id: policy-id })
)

(define-read-only (get-policy-by-property (property-id uint))
  (match (map-get? policy-by-property { property-id: property-id })
    policy-info (map-get? insurance-policies { policy-id: (get policy-id policy-info) })
    none
  )
)

(define-read-only (get-claim (claim-id uint))
  (map-get? claims { claim-id: claim-id })
)

(define-read-only (get-claim-for-earthquake (policy-id uint) (earthquake-id uint))
  (match (map-get? policy-claims-history { policy-id: policy-id, earthquake-id: earthquake-id })
    claim-info (map-get? claims { claim-id: (get claim-id claim-info) })
    none
  )
)

(define-read-only (get-insurance-pool-balance)
  (var-get insurance-pool-balance)
)

(define-read-only (get-total-policies)
  (var-get total-policies)
)

(define-read-only (get-total-claims)
  (var-get total-claims)
)

(define-read-only (get-total-payouts)
  (var-get total-payouts)
)

(define-read-only (is-payout-enabled)
  (var-get payout-enabled)
)

(define-read-only (is-authorized-processor (processor principal))
  (match (map-get? processor-permissions { processor: processor })
    permission-data (get authorized permission-data)
    false
  )
)

(define-read-only (calculate-annual-premium (coverage-amount uint))
  (/ (* coverage-amount PREMIUM_RATE) u10000)
)

(define-read-only (is-policy-active (policy-id uint))
  (match (map-get? insurance-policies { policy-id: policy-id })
    policy-data (and
      (get active policy-data)
      (<= stacks-block-height (get policy-end-block policy-data))
    )
    false
  )
)

;; Private functions
(define-private (validate-policy-data (coverage-amount uint) (property-id uint))
  (and
    (>= coverage-amount MIN_POLICY_AMOUNT)
    (<= coverage-amount MAX_POLICY_AMOUNT)
    (> property-id u0)
  )
)

(define-private (calculate-claim-amount (coverage-amount uint) (damage-percentage uint))
  (/ (* coverage-amount damage-percentage) u10000)
)

(define-private (remove-processor-from-list (processor principal))
  (not (is-eq processor tx-sender))
)

(define-private (transfer-payout (recipient principal) (amount uint))
  ;; Simulate STX transfer from insurance pool
  ;; In a real implementation, this would use stx-transfer?
  (begin
    (var-set insurance-pool-balance (- (var-get insurance-pool-balance) amount))
    (ok amount)
  )
)

;; Public functions
(define-public (add-authorized-processor (processor principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set processor-permissions
      { processor: processor }
      { authorized: true, added-at: stacks-block-height }
    )
    (var-set authorized-processors
      (unwrap-panic (as-max-len? (append (var-get authorized-processors) processor) u10))
    )
    (ok true)
  )
)

(define-public (remove-authorized-processor (processor principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set processor-permissions
      { processor: processor }
      { authorized: false, added-at: stacks-block-height }
    )
    (var-set authorized-processors
      (filter remove-processor-from-list (var-get authorized-processors))
    )
    (ok true)
  )
)

(define-public (create-insurance-policy
  (property-id uint)
  (coverage-amount uint)
  (policy-duration-blocks uint)
)
  (begin
    (asserts! (validate-policy-data coverage-amount property-id) ERR_INVALID_POLICY_DATA)
    (asserts! (is-none (map-get? policy-by-property { property-id: property-id })) ERR_POLICY_NOT_FOUND)
    
    (let (
      (policy-id (var-get next-policy-id))
      (premium-amount (calculate-annual-premium coverage-amount))
      (policy-end-block (+ stacks-block-height policy-duration-blocks))
    )
      ;; Create policy
      (map-set insurance-policies
        { policy-id: policy-id }
        {
          policyholder: tx-sender,
          property-id: property-id,
          coverage-amount: coverage-amount,
          premium-paid: premium-amount,
          policy-start-block: stacks-block-height,
          policy-end-block: policy-end-block,
          active: true,
          total-claims: u0,
          total-payouts-received: u0
        }
      )
      
      ;; Create property mapping
      (map-set policy-by-property
        { property-id: property-id }
        { policy-id: policy-id }
      )
      
      ;; Record premium payment
      (map-set premium-payments
        { policy-id: policy-id, payment-block: stacks-block-height }
        { amount: premium-amount, paid-by: tx-sender }
      )
      
      ;; Add premium to insurance pool
      (var-set insurance-pool-balance (+ (var-get insurance-pool-balance) premium-amount))
      
      ;; Update counters
      (var-set next-policy-id (+ policy-id u1))
      (var-set total-policies (+ (var-get total-policies) u1))
      
      (ok policy-id)
    )
  )
)

(define-public (submit-insurance-claim
  (policy-id uint)
  (earthquake-id uint)
  (assessment-id uint)
  (damage-percentage uint)
)
  (begin
    (let (
      (policy-data (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND))
      (claim-id (var-get next-claim-id))
    )
      (asserts! (is-eq tx-sender (get policyholder policy-data)) ERR_UNAUTHORIZED)
      (asserts! (is-policy-active policy-id) ERR_POLICY_INACTIVE)
      (asserts! (>= damage-percentage MIN_DAMAGE_THRESHOLD) ERR_MINIMUM_DAMAGE_NOT_MET)
      (asserts! (is-none (map-get? policy-claims-history { policy-id: policy-id, earthquake-id: earthquake-id })) ERR_CLAIM_ALREADY_PROCESSED)
      
      (let (
        (claim-amount (calculate-claim-amount (get coverage-amount policy-data) damage-percentage))
      )
        ;; Create claim
        (map-set claims
          { claim-id: claim-id }
          {
            policy-id: policy-id,
            earthquake-id: earthquake-id,
            assessment-id: assessment-id,
            claim-amount: claim-amount,
            damage-percentage: damage-percentage,
            submitted-at: stacks-block-height,
            processed-at: u0,
            status: "pending",
            processor: none,
            payout-transaction: none
          }
        )
        
        ;; Create claim history
        (map-set policy-claims-history
          { policy-id: policy-id, earthquake-id: earthquake-id }
          { claim-id: claim-id }
        )
        
        ;; Update policy claim count
        (map-set insurance-policies
          { policy-id: policy-id }
          (merge policy-data { total-claims: (+ (get total-claims policy-data) u1) })
        )
        
        ;; Update counters
        (var-set next-claim-id (+ claim-id u1))
        (var-set total-claims (+ (var-get total-claims) u1))
        
        (ok claim-id)
      )
    )
  )
)

(define-public (process-claim (claim-id uint) (approve bool))
  (begin
    (asserts! (is-authorized-processor tx-sender) ERR_UNAUTHORIZED)
    (asserts! (var-get payout-enabled) ERR_PAYOUT_DISABLED)
    
    (let (
      (claim-data (unwrap! (map-get? claims { claim-id: claim-id }) ERR_CLAIM_NOT_FOUND))
    )
      (asserts! (is-eq (get status claim-data) "pending") ERR_CLAIM_ALREADY_PROCESSED)
      (asserts! (<= (- stacks-block-height (get submitted-at claim-data)) CLAIM_EXPIRY_BLOCKS) ERR_CLAIM_EXPIRED)
      
      (if approve
        (begin
          ;; Approve and pay claim
          (asserts! (>= (var-get insurance-pool-balance) (get claim-amount claim-data)) ERR_INSUFFICIENT_FUNDS)
          
          (let (
            (policy-data (unwrap-panic (map-get? insurance-policies { policy-id: (get policy-id claim-data) })))
            (payout-result (unwrap-panic (transfer-payout (get policyholder policy-data) (get claim-amount claim-data))))
          )
            ;; Update claim status
            (map-set claims
              { claim-id: claim-id }
              (merge claim-data {
                status: "paid",
                processed-at: stacks-block-height,
                processor: (some tx-sender),
                payout-transaction: (some stacks-block-height)
              })
            )
            
            ;; Update policy payout total
            (map-set insurance-policies
              { policy-id: (get policy-id claim-data) }
              (merge policy-data {
                total-payouts-received: (+ (get total-payouts-received policy-data) (get claim-amount claim-data))
              })
            )
            
            ;; Update total payouts
            (var-set total-payouts (+ (var-get total-payouts) (get claim-amount claim-data)))
            
            (ok (get claim-amount claim-data))
          )
        )
        (begin
          ;; Deny claim
          (map-set claims
            { claim-id: claim-id }
            (merge claim-data {
              status: "denied",
              processed-at: stacks-block-height,
              processor: (some tx-sender)
            })
          )
          (ok u0)
        )
      )
    )
  )
)

(define-public (renew-policy (policy-id uint) (additional-blocks uint))
  (begin
    (let (
      (policy-data (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND))
    )
      (asserts! (is-eq tx-sender (get policyholder policy-data)) ERR_UNAUTHORIZED)
      
      (let (
        (renewal-premium (calculate-annual-premium (get coverage-amount policy-data)))
        (new-end-block (+ (get policy-end-block policy-data) additional-blocks))
      )
        ;; Update policy
        (map-set insurance-policies
          { policy-id: policy-id }
          (merge policy-data {
            policy-end-block: new-end-block,
            premium-paid: (+ (get premium-paid policy-data) renewal-premium),
            active: true
          })
        )
        
        ;; Record premium payment
        (map-set premium-payments
          { policy-id: policy-id, payment-block: stacks-block-height }
          { amount: renewal-premium, paid-by: tx-sender }
        )
        
        ;; Add to insurance pool
        (var-set insurance-pool-balance (+ (var-get insurance-pool-balance) renewal-premium))
        
        (ok new-end-block)
      )
    )
  )
)

(define-public (contribute-to-insurance-pool (amount uint))
  (begin
    (asserts! (> amount u0) ERR_INSUFFICIENT_FUNDS)
    
    ;; Add contribution to pool
    (var-set insurance-pool-balance (+ (var-get insurance-pool-balance) amount))
    
    ;; Record contribution
    (let (
      (existing-contrib (default-to 
        { total-contributed: u0, contribution-blocks: (list) }
        (map-get? insurance-pool-contributions { contributor: tx-sender })))
    )
      (map-set insurance-pool-contributions
        { contributor: tx-sender }
        {
          total-contributed: (+ (get total-contributed existing-contrib) amount),
          contribution-blocks: (unwrap-panic (as-max-len? 
            (append (get contribution-blocks existing-contrib) stacks-block-height) u100))
        }
      )
    )
    
    (ok amount)
  )
)

(define-public (set-payout-enabled (enabled bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set payout-enabled enabled)
    (ok enabled)
  )
)

(define-public (cancel-policy (policy-id uint))
  (begin
    (let (
      (policy-data (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND))
    )
      (asserts! (is-eq tx-sender (get policyholder policy-data)) ERR_UNAUTHORIZED)
      (asserts! (get active policy-data) ERR_POLICY_INACTIVE)
      
      ;; Deactivate policy
      (map-set insurance-policies
        { policy-id: policy-id }
        (merge policy-data { active: false })
      )
      
      (ok true)
    )
  )
)

