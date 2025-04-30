;; carbon-marketplace.clar
;; Carbon Credit Marketplace - Core contract for managing carbon credits on the Stacks blockchain
;; This contract handles the minting, trading, retirement, and verification of carbon credits
;; Each credit represents a specific quantity of carbon offset (typically 1 ton of CO2)

;; ========== Error Constants ==========
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-PRODUCER-NOT-VERIFIED (err u101))
(define-constant ERR-INVALID-PRICE (err u102))
(define-constant ERR-LISTING-NOT-FOUND (err u103))
(define-constant ERR-ALREADY-LISTED (err u104))
(define-constant ERR-NOT-OWNER (err u105))
(define-constant ERR-CREDIT-ALREADY-RETIRED (err u106))
(define-constant ERR-INSUFFICIENT-FUNDS (err u107))
(define-constant ERR-INVALID-CREDIT-ID (err u108))
(define-constant ERR-INVALID-QUANTITY (err u109))
(define-constant ERR-PRODUCER-ALREADY-VERIFIED (err u110))
(define-constant ERR-INVALID-PROJECT-DATA (err u111))
(define-constant ERR-AUCTION-ALREADY-ENDED (err u112))
(define-constant ERR-BID-TOO-LOW (err u113))
(define-constant ERR-AUCTION-STILL-ACTIVE (err u114))

;; ========== Contract Variables ==========
;; Contract owner has special privileges for verifying producers
(define-data-var contract-owner principal tx-sender)

;; ID counter for carbon credits - incremented each time a new credit is minted
(define-data-var credit-id-counter uint u0)

;; ID counter for listings - incremented each time a new listing is created
(define-data-var listing-id-counter uint u0)

;; ID counter for auctions - incremented each time a new auction is created
(define-data-var auction-id-counter uint u0)

;; ========== Data Maps ==========
;; Map of verified carbon credit producers
;; Producers must be verified before they can mint credits
(define-map verified-producers 
  principal 
  {
    verified: bool,
    verification-date: uint,
    project-name: (string-ascii 100),
    project-location: (string-ascii 100),
    verification-authority: (string-ascii 100)
  }
)

;; Map of carbon credits with their metadata
(define-map carbon-credits 
  uint  ;; credit-id
  {
    owner: principal,
    producer: principal,
    project-name: (string-ascii 100),
    verification-date: uint, 
    quantity: uint,            ;; CO2 offset in tons
    credit-type: (string-ascii 50),  ;; e.g., "Reforestation", "Renewable Energy", etc.
    retired: bool,             ;; Whether the credit has been retired/used
    retirement-date: (optional uint),
    retirement-beneficiary: (optional principal),
    metadata-url: (string-utf8 256)  ;; URL to additional metadata (IPFS or HTTP)
  }
)

;; Map of credit owners to their credit IDs
(define-map credit-owners 
  principal 
  (list 50 uint)  ;; List of credit IDs owned by this principal
)

;; Map of active marketplace listings
(define-map listings 
  uint  ;; listing-id
  {
    credit-id: uint,
    seller: principal,
    price: uint,            ;; Price in STX
    listed-at: uint,        ;; Block height when listed
    active: bool
  }
)

;; Map of active auctions
(define-map auctions
  uint  ;; auction-id
  {
    credit-id: uint,
    seller: principal,
    minimum-bid: uint,      ;; Minimum bid in STX
    current-bid: uint,      ;; Current highest bid
    current-bidder: (optional principal),
    end-block-height: uint, ;; Block when auction ends
    started-at: uint,       ;; Block height when started
    active: bool
  }
)

;; ========== Private Functions ==========

;; Add a credit ID to a user's list of owned credits
(define-private (add-credit-to-owner (owner principal) (credit-id uint))
  (let (
    (current-credits (default-to (list) (map-get? credit-owners owner)))
  )
    (map-set credit-owners owner (append current-credits credit-id))
  )
)

;; Remove a credit ID from a user's list of owned credits
(define-private (remove-credit-from-owner (owner principal) (credit-id uint))
  (let (
    (current-credits (default-to (list) (map-get? credit-owners owner)))
    (new-credits (filter remove-credit-filter current-credits))
  )
    (map-set credit-owners owner new-credits)
  )
  (where remove-credit-filter (lambda (id) (not (is-eq id credit-id))))
)

;; Transfer a credit from one owner to another
(define-private (transfer-credit (credit-id uint) (sender principal) (recipient principal))
  (let (
    (credit (unwrap! (map-get? carbon-credits credit-id) ERR-INVALID-CREDIT-ID))
  )
    ;; Update credit ownership
    (map-set carbon-credits 
      credit-id
      (merge credit { owner: recipient })
    )
    
    ;; Update owner mappings
    (remove-credit-from-owner sender credit-id)
    (add-credit-to-owner recipient credit-id)
    
    (ok true)
  )
)

;; Check if a producer is verified
(define-private (is-verified-producer (producer principal))
  (default-to false (get verified (map-get? verified-producers producer)))
)

;; Get the current block height (for timestamps)
(define-private (get-block-height)
  block-height
)

;; ========== Read-Only Functions ==========

;; Get credit details by ID
(define-read-only (get-credit (credit-id uint))
  (map-get? carbon-credits credit-id)
)

;; Get listing details by ID
(define-read-only (get-listing (listing-id uint))
  (map-get? listings listing-id)
)

;; Get auction details by ID
(define-read-only (get-auction (auction-id uint))
  (map-get? auctions auction-id)
)

;; Check if a credit is retired/used
(define-read-only (is-credit-retired (credit-id uint))
  (default-to true (get retired (map-get? carbon-credits credit-id)))
)

;; Get credits owned by an address
(define-read-only (get-credits-by-owner (owner principal))
  (default-to (list) (map-get? credit-owners owner))
)

;; Check if a user is the owner of a specific credit
(define-read-only (is-credit-owner (credit-id uint) (user principal))
  (let (
    (credit (map-get? carbon-credits credit-id))
  )
    (and 
      (is-some credit)
      (is-eq (get owner (unwrap! credit false)) user)
    )
  )
)

;; Get producer verification status
(define-read-only (get-producer-status (producer principal))
  (map-get? verified-producers producer)
)

;; Check if an auction has ended
(define-read-only (is-auction-ended (auction-id uint))
  (let (
    (auction (map-get? auctions auction-id))
  )
    (if (is-some auction)
      (>= block-height (get end-block-height (unwrap! auction false)))
      false
    )
  )
)

;; ========== Public Functions ==========

;; Set a new contract owner
(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (ok (var-set contract-owner new-owner))
  )
)

;; Verify a carbon credit producer
(define-public (verify-producer 
    (producer principal) 
    (project-name (string-ascii 100))
    (project-location (string-ascii 100))
    (verification-authority (string-ascii 100))
  )
  (begin
    ;; Only contract owner can verify producers
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    ;; Check if producer is already verified
    (asserts! (not (is-verified-producer producer)) ERR-PRODUCER-ALREADY-VERIFIED)
    
    ;; Validate project data
    (asserts! (and 
               (> (len project-name) u0) 
               (> (len project-location) u0)
               (> (len verification-authority) u0)
              ) 
              ERR-INVALID-PROJECT-DATA)
    
    ;; Add producer to verified list
    (map-set verified-producers producer {
      verified: true,
      verification-date: block-height,
      project-name: project-name,
      project-location: project-location,
      verification-authority: verification-authority
    })
    
    (ok true)
  )
)

;; Mint a new carbon credit
(define-public (mint-carbon-credit 
    (quantity uint)  ;; CO2 offset in tons
    (project-name (string-ascii 100))
    (credit-type (string-ascii 50))
    (metadata-url (string-utf8 256))
  )
  (let (
    (producer tx-sender)
    (new-id (+ (var-get credit-id-counter) u1))
  )
    ;; Validate producer is verified
    (asserts! (is-verified-producer producer) ERR-PRODUCER-NOT-VERIFIED)
    
    ;; Validate quantity is positive
    (asserts! (> quantity u0) ERR-INVALID-QUANTITY)
    
    ;; Increment credit ID counter
    (var-set credit-id-counter new-id)
    
    ;; Create the new carbon credit
    (map-set carbon-credits new-id {
      owner: producer,
      producer: producer,
      project-name: project-name,
      verification-date: block-height,
      quantity: quantity,
      credit-type: credit-type,
      retired: false,
      retirement-date: none,
      retirement-beneficiary: none,
      metadata-url: metadata-url
    })
    
    ;; Add credit to producer's owned credits
    (add-credit-to-owner producer new-id)
    
    (ok new-id)
  )
)

;; List a carbon credit for sale at a fixed price
(define-public (list-credit-for-sale (credit-id uint) (price uint))
  (let (
    (seller tx-sender)
    (new-listing-id (+ (var-get listing-id-counter) u1))
  )
    ;; Check if seller owns the credit
    (asserts! (is-credit-owner credit-id seller) ERR-NOT-OWNER)
    
    ;; Check if credit is already retired
    (asserts! (not (is-credit-retired credit-id)) ERR-CREDIT-ALREADY-RETIRED)
    
    ;; Validate price is positive
    (asserts! (> price u0) ERR-INVALID-PRICE)
    
    ;; Increment listing ID counter
    (var-set listing-id-counter new-listing-id)
    
    ;; Create new listing
    (map-set listings new-listing-id {
      credit-id: credit-id,
      seller: seller,
      price: price,
      listed-at: block-height,
      active: true
    })
    
    (ok new-listing-id)
  )
)

;; Cancel a listing
(define-public (cancel-listing (listing-id uint))
  (let (
    (listing (unwrap! (map-get? listings listing-id) ERR-LISTING-NOT-FOUND))
  )
    ;; Check that sender is the seller
    (asserts! (is-eq tx-sender (get seller listing)) ERR-NOT-AUTHORIZED)
    
    ;; Check that listing is active
    (asserts! (get active listing) ERR-LISTING-NOT-FOUND)
    
    ;; Deactivate the listing
    (map-set listings listing-id (merge listing { active: false }))
    
    (ok true)
  )
)

;; Buy a listed carbon credit
(define-public (buy-credit (listing-id uint))
  (let (
    (listing (unwrap! (map-get? listings listing-id) ERR-LISTING-NOT-FOUND))
    (buyer tx-sender)
    (price (get price listing))
    (credit-id (get credit-id listing))
    (seller (get seller listing))
  )
    ;; Check that listing is active
    (asserts! (get active listing) ERR-LISTING-NOT-FOUND)
    
    ;; Check that credit is not retired
    (asserts! (not (is-credit-retired credit-id)) ERR-CREDIT-ALREADY-RETIRED)
    
    ;; Process payment from buyer to seller
    (try! (stx-transfer? price buyer seller))
    
    ;; Transfer credit ownership
    (try! (transfer-credit credit-id seller buyer))
    
    ;; Deactivate the listing
    (map-set listings listing-id (merge listing { active: false }))
    
    (ok true)
  )
)

;; Retire a carbon credit (permanently mark as used)
(define-public (retire-credit (credit-id uint) (beneficiary (optional principal)))
  (let (
    (owner tx-sender)
    (credit (unwrap! (map-get? carbon-credits credit-id) ERR-INVALID-CREDIT-ID))
  )
    ;; Check that sender is the owner
    (asserts! (is-eq owner (get owner credit)) ERR-NOT-OWNER)
    
    ;; Check that credit is not already retired
    (asserts! (not (get retired credit)) ERR-CREDIT-ALREADY-RETIRED)
    
    ;; Update credit to retired status
    (map-set carbon-credits credit-id (merge credit {
      retired: true,
      retirement-date: (some block-height),
      retirement-beneficiary: beneficiary
    }))
    
    (ok true)
  )
)

;; Create a new auction for a carbon credit
(define-public (create-auction (credit-id uint) (minimum-bid uint) (blocks-duration uint))
  (let (
    (seller tx-sender)
    (new-auction-id (+ (var-get auction-id-counter) u1))
    (end-block (+ block-height blocks-duration))
  )
    ;; Check if seller owns the credit
    (asserts! (is-credit-owner credit-id seller) ERR-NOT-OWNER)
    
    ;; Check if credit is already retired
    (asserts! (not (is-credit-retired credit-id)) ERR-CREDIT-ALREADY-RETIRED)
    
    ;; Validate minimum bid is positive
    (asserts! (> minimum-bid u0) ERR-INVALID-PRICE)
    
    ;; Validate auction duration is reasonable
    (asserts! (> blocks-duration u10) ERR-INVALID-PRICE)
    
    ;; Increment auction ID counter
    (var-set auction-id-counter new-auction-id)
    
    ;; Create new auction
    (map-set auctions new-auction-id {
      credit-id: credit-id,
      seller: seller,
      minimum-bid: minimum-bid,
      current-bid: u0,
      current-bidder: none,
      end-block-height: end-block,
      started-at: block-height,
      active: true
    })
    
    (ok new-auction-id)
  )
)

;; Place a bid on an auction
(define-public (place-bid (auction-id uint) (bid-amount uint))
  (let (
    (auction (unwrap! (map-get? auctions auction-id) ERR-LISTING-NOT-FOUND))
    (bidder tx-sender)
  )
    ;; Check that auction is active
    (asserts! (get active auction) ERR-LISTING-NOT-FOUND)
    
    ;; Check that auction hasn't ended
    (asserts! (< block-height (get end-block-height auction)) ERR-AUCTION-ALREADY-ENDED)
    
    ;; Check if bid is higher than minimum and current bid
    (asserts! (>= bid-amount (get minimum-bid auction)) ERR-BID-TOO-LOW)
    (asserts! (> bid-amount (get current-bid auction)) ERR-BID-TOO-LOW)
    
    ;; Process bid payment
    ;; We'll hold it in this contract until auction ends or is outbid
    (try! (stx-transfer? bid-amount bidder (as-contract tx-sender)))
    
    ;; Refund previous bidder if there was one
    (match (get current-bidder auction)
      prev-bidder (as-contract (stx-transfer? (get current-bid auction) tx-sender prev-bidder))
      true
    )
    
    ;; Update auction with new bid
    (map-set auctions auction-id (merge auction {
      current-bid: bid-amount,
      current-bidder: (some bidder)
    }))
    
    (ok true)
  )
)

;; Finalize an auction after it has ended
(define-public (finalize-auction (auction-id uint))
  (let (
    (auction (unwrap! (map-get? auctions auction-id) ERR-LISTING-NOT-FOUND))
    (credit-id (get credit-id auction))
    (seller (get seller auction))
  )
    ;; Check that auction is active
    (asserts! (get active auction) ERR-LISTING-NOT-FOUND)
    
    ;; Check that auction has ended
    (asserts! (>= block-height (get end-block-height auction)) ERR-AUCTION-STILL-ACTIVE)
    
    ;; If there were bids, transfer payment to seller and credit to winning bidder
    (match (get current-bidder auction)
      winner (begin
        ;; Transfer payment from contract to seller
        (try! (as-contract (stx-transfer? (get current-bid auction) tx-sender seller)))
        
        ;; Transfer credit to winner
        (try! (transfer-credit credit-id seller winner))
        
        ;; Deactivate the auction
        (map-set auctions auction-id (merge auction { active: false }))
        
        (ok true)
      )
      ;; If no bids, just deactivate the auction
      (begin
        (map-set auctions auction-id (merge auction { active: false }))
        (ok true)
      )
    )
  )
)

;; Transfer a carbon credit to another user
(define-public (transfer-credit-to (credit-id uint) (recipient principal))
  (let (
    (sender tx-sender)
  )
    ;; Check if sender owns the credit
    (asserts! (is-credit-owner credit-id sender) ERR-NOT-OWNER)
    
    ;; Check if credit is already retired
    (asserts! (not (is-credit-retired credit-id)) ERR-CREDIT-ALREADY-RETIRED)
    
    ;; Transfer the credit
    (try! (transfer-credit credit-id sender recipient))
    
    (ok true)
  )
)