;; vr-asset-registry
;; 
;; This contract implements a registry for VR assets on the Stacks blockchain.
;; It allows creators to mint, transfer, and manage ownership of 3D models, environments,
;; avatars, and other digital assets used in VR experiences, with specialized metadata
;; for VR-specific attributes like spatial dimensions and platform compatibility.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-ASSET-EXISTS (err u1001))
(define-constant ERR-ASSET-NOT-FOUND (err u1002))
(define-constant ERR-NOT-OWNER (err u1003))
(define-constant ERR-INVALID-METADATA (err u1004))
(define-constant ERR-UNAUTHORIZED-TRANSFER (err u1005))
(define-constant ERR-ROYALTY-EXCEEDS-MAX (err u1006))
(define-constant ERR-INVALID-RECIPIENT (err u1007))
(define-constant ERR-ZERO-ASSET-ID (err u1008))

;; Constants
(define-constant MAX-ROYALTY-PERCENTAGE u1000) ;; 10.00% (using basis points: 1000 = 10%)
(define-constant CONTRACT-OWNER tx-sender)

;; Data structures

;; Asset metadata: Stores the detailed information about a VR asset
(define-map asset-metadata
  { asset-id: uint }
  {
    name: (string-ascii 64),
    description: (string-utf8 256),
    creator: principal,
    creation-time: uint,
    spatial-dimensions: {x: uint, y: uint, z: uint},
    file-url: (string-ascii 256),
    file-hash: (buff 32),
    platform-compatibility: (list 10 (string-ascii 32)), ;; List of compatible platforms
    rendering-requirements: {
      min-gpu: (string-ascii 64),
      recommended-gpu: (string-ascii 64),
      min-cpu: (string-ascii 64),
      other-requirements: (string-utf8 256)
    },
    royalty-percentage: uint, ;; In basis points (e.g., 250 = 2.5%)
    additional-metadata: (optional (string-utf8 1024))
  }
)

;; Asset ownership: Maps asset IDs to their current owners
(define-map asset-ownership
  { asset-id: uint }
  { owner: principal }
)

;; Asset existence check: Simple map to quickly check if an asset ID exists
(define-map asset-exists
  { asset-id: uint }
  { exists: bool }
)

;; User assets: Maps users to their owned assets for easy lookup
(define-map user-assets
  { user: principal }
  { asset-ids: (list 100 uint) }
)

;; Counter for generating new asset IDs
(define-data-var next-asset-id uint u1)

;; Functions

;; Private helper functions

;; Adds an asset ID to a user's asset list
(define-private (add-asset-to-user (user principal) (asset-id uint))
  (let ((current-assets (default-to {asset-ids: (list)} (map-get? user-assets {user: user}))))
    (map-set user-assets
      {user: user}
      {asset-ids: (unwrap-panic (as-max-len? (append (get asset-ids current-assets) asset-id) u100))}
    )
  )
)

;; Removes an asset ID from a user's asset list
(define-private (remove-asset-from-user (user principal) (asset-id uint))
  (let ((current-assets (default-to {asset-ids: (list)} (map-get? user-assets {user: user}))))
    (map-set user-assets
      {user: user}
      {asset-ids: (filter (lambda (id) (not (is-eq id asset-id))) (get asset-ids current-assets))}
    )
  )
)

;; Checks if the caller is the owner of an asset
(define-private (is-owner (asset-id uint) (caller principal))
  (let ((ownership (map-get? asset-ownership {asset-id: asset-id})))
    (and
      (is-some ownership)
      (is-eq caller (get owner (unwrap-panic ownership)))
    )
  )
)

;; Public functions

;; Registers a new VR asset in the registry
;; Returns the newly created asset ID
(define-public (register-asset 
  (name (string-ascii 64))
  (description (string-utf8 256))
  (spatial-dimensions {x: uint, y: uint, z: uint})
  (file-url (string-ascii 256))
  (file-hash (buff 32))
  (platform-compatibility (list 10 (string-ascii 32)))
  (rendering-requirements {
    min-gpu: (string-ascii 64),
    recommended-gpu: (string-ascii 64),
    min-cpu: (string-ascii 64),
    other-requirements: (string-utf8 256)
  })
  (royalty-percentage uint)
  (additional-metadata (optional (string-utf8 1024)))
)
  (let 
    (
      (asset-id (var-get next-asset-id))
      (creator tx-sender)
      (creation-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    
    ;; Validate royalty percentage
    (asserts! (<= royalty-percentage MAX-ROYALTY-PERCENTAGE) ERR-ROYALTY-EXCEEDS-MAX)
    
    ;; Create the asset metadata
    (map-set asset-metadata
      {asset-id: asset-id}
      {
        name: name,
        description: description,
        creator: creator,
        creation-time: creation-time,
        spatial-dimensions: spatial-dimensions,
        file-url: file-url,
        file-hash: file-hash,
        platform-compatibility: platform-compatibility,
        rendering-requirements: rendering-requirements,
        royalty-percentage: royalty-percentage,
        additional-metadata: additional-metadata
      }
    )
    
    ;; Set ownership
    (map-set asset-ownership
      {asset-id: asset-id}
      {owner: creator}
    )
    
    ;; Mark asset as existing
    (map-set asset-exists
      {asset-id: asset-id}
      {exists: true}
    )
    
    ;; Add to creator's assets
    (add-asset-to-user creator asset-id)
    
    ;; Increment the asset ID counter
    (var-set next-asset-id (+ asset-id u1))
    
    ;; Return the new asset ID
    (ok asset-id)
  )
)

;; Transfers ownership of an asset
(define-public (transfer-asset (asset-id uint) (recipient principal))
  (let 
    (
      (sender tx-sender)
    )
    ;; Verify the asset exists
    (asserts! (default-to false (get exists (map-get? asset-exists {asset-id: asset-id}))) ERR-ASSET-NOT-FOUND)
    
    ;; Verify sender owns the asset
    (asserts! (is-owner asset-id sender) ERR-NOT-OWNER)
    
    ;; Verify valid recipient
    (asserts! (not (is-eq recipient sender)) ERR-INVALID-RECIPIENT)
    
    ;; Update ownership
    (map-set asset-ownership
      {asset-id: asset-id}
      {owner: recipient}
    )
    
    ;; Update user assets lists
    (remove-asset-from-user sender asset-id)
    (add-asset-to-user recipient asset-id)
    
    (ok true)
  )
)

;; Updates the metadata of an existing asset (only by asset owner)
(define-public (update-asset-metadata
  (asset-id uint)
  (name (string-ascii 64))
  (description (string-utf8 256))
  (file-url (string-ascii 256))
  (platform-compatibility (list 10 (string-ascii 32)))
  (rendering-requirements {
    min-gpu: (string-ascii 64),
    recommended-gpu: (string-ascii 64),
    min-cpu: (string-ascii 64),
    other-requirements: (string-utf8 256)
  })
  (additional-metadata (optional (string-utf8 1024)))
)
  (let
    (
      (sender tx-sender)
      (metadata (map-get? asset-metadata {asset-id: asset-id}))
    )
    ;; Verify the asset exists
    (asserts! (is-some metadata) ERR-ASSET-NOT-FOUND)
    
    ;; Verify sender owns the asset
    (asserts! (is-owner asset-id sender) ERR-NOT-OWNER)
    
    ;; Update the metadata, preserving immutable fields
    (map-set asset-metadata
      {asset-id: asset-id}
      (merge (unwrap-panic metadata)
        {
          name: name,
          description: description,
          file-url: file-url,
          platform-compatibility: platform-compatibility,
          rendering-requirements: rendering-requirements,
          additional-metadata: additional-metadata
        }
      )
    )
    
    (ok true)
  )
)

;; Updates the royalty percentage for an asset (only by creator)
(define-public (update-royalty-percentage (asset-id uint) (royalty-percentage uint))
  (let
    (
      (sender tx-sender)
      (metadata (map-get? asset-metadata {asset-id: asset-id}))
    )
    ;; Verify the asset exists
    (asserts! (is-some metadata) ERR-ASSET-NOT-FOUND)
    
    ;; Verify sender is the creator
    (asserts! (is-eq sender (get creator (unwrap-panic metadata))) ERR-NOT-AUTHORIZED)
    
    ;; Validate royalty percentage
    (asserts! (<= royalty-percentage MAX-ROYALTY-PERCENTAGE) ERR-ROYALTY-EXCEEDS-MAX)
    
    ;; Update the royalty percentage
    (map-set asset-metadata
      {asset-id: asset-id}
      (merge (unwrap-panic metadata) {royalty-percentage: royalty-percentage})
    )
    
    (ok true)
  )
)

;; Read-only functions

;; Gets an asset's metadata
(define-read-only (get-asset-metadata (asset-id uint))
  (map-get? asset-metadata {asset-id: asset-id})
)

;; Gets an asset's current owner
(define-read-only (get-asset-owner (asset-id uint))
  (map-get? asset-ownership {asset-id: asset-id})
)

;; Gets all assets owned by a particular user
(define-read-only (get-user-assets (user principal))
  (default-to {asset-ids: (list)} (map-get? user-assets {user: user}))
)

;; Verify if an asset exists
(define-read-only (asset-exists? (asset-id uint))
  (default-to false (get exists (map-get? asset-exists {asset-id: asset-id})))
)

;; Checks if a user is the current owner of an asset
(define-read-only (is-asset-owner (asset-id uint) (user principal))
  (is-owner asset-id user)
)

;; Gets the royalty info for an asset (creator and percentage)
(define-read-only (get-royalty-info (asset-id uint))
  (let ((metadata (map-get? asset-metadata {asset-id: asset-id})))
    (if (is-some metadata)
      (some {
        creator: (get creator (unwrap-panic metadata)),
        royalty-percentage: (get royalty-percentage (unwrap-panic metadata))
      })
      none
    )
  )
)

;; Gets the VR platform compatibility for an asset
(define-read-only (get-platform-compatibility (asset-id uint))
  (let ((metadata (map-get? asset-metadata {asset-id: asset-id})))
    (if (is-some metadata)
      (some (get platform-compatibility (unwrap-panic metadata)))
      none
    )
  )
)

;; Gets the total number of registered assets
(define-read-only (get-asset-count)
  (- (var-get next-asset-id) u1)
)