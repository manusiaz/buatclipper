
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "api": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            "admin_ledger": {
                  Row: {
                    "amount": number | null,"created_at": string | null,"id": number | null,"owner_id": string | null,"owner_type": string | null,"ref_id": string | null,"ref_type": string | null,"reward_type": string | null,"state": "pending"|"available"|"withdrawn" | null,"txn_id": string | null
                  }
                  ComputedFields: never
                  Relationships: [
                    
                  ]
                },"admin_profiles": {
                  Row: {
                    "avatar_path": string | null,"created_at": string | null,"display_name": string | null,"id": string | null,"status": "active"|"suspended"|"banned"|"closed" | null,"suspended_until": string | null,"trust_score": number | null,"username": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "avatar_path"?: string | null,"created_at"?: string | null,"display_name"?: string | null,"id"?: string | null,"status"?: "active"|"suspended"|"banned"|"closed" | null,"suspended_until"?: string | null,"trust_score"?: number | null,"username"?: string | null
                         }
                        Update: {
                           "avatar_path"?: string | null,"created_at"?: string | null,"display_name"?: string | null,"id"?: string | null,"status"?: "active"|"suspended"|"banned"|"closed" | null,"suspended_until"?: string | null,"trust_score"?: number | null,"username"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"alerts": {
                  Row: {
                    "created_at": string | null,"id": number | null,"kind": string | null,"payload": Json | null,"resolved_at": string | null,"resolved_by": string | null,"severity": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "created_at"?: string | null,"id"?: number | null,"kind"?: string | null,"payload"?: Json | null,"resolved_at"?: string | null,"resolved_by"?: string | null,"severity"?: string | null
                         }
                        Update: {
                           "created_at"?: string | null,"id"?: number | null,"kind"?: string | null,"payload"?: Json | null,"resolved_at"?: string | null,"resolved_by"?: string | null,"severity"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"audit_logs": {
                  Row: {
                    "action": string | null,"actor_id": string | null,"after": Json | null,"at": string | null,"before": Json | null,"id": number | null,"target": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "action"?: string | null,"actor_id"?: string | null,"after"?: Json | null,"at"?: string | null,"before"?: Json | null,"id"?: number | null,"target"?: string | null
                         }
                        Update: {
                           "action"?: string | null,"actor_id"?: string | null,"after"?: Json | null,"at"?: string | null,"before"?: Json | null,"id"?: number | null,"target"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"bank_lines": {
                  Row: {
                    "amount": number | null,"description": string | null,"id": number | null,"imported_at": string | null,"note": string | null,"reference": string | null,"resolved_at": string | null,"status": string | null,"value_date": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "amount"?: number | null,"description"?: string | null,"id"?: number | null,"imported_at"?: string | null,"note"?: string | null,"reference"?: string | null,"resolved_at"?: string | null,"status"?: string | null,"value_date"?: string | null
                         }
                        Update: {
                           "amount"?: number | null,"description"?: string | null,"id"?: number | null,"imported_at"?: string | null,"note"?: string | null,"reference"?: string | null,"resolved_at"?: string | null,"status"?: string | null,"value_date"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"broadcasts": {
                  Row: {
                    "body": string | null,"channels": (string)[] | null,"created_by": string | null,"id": string | null,"recipient_count": number | null,"scheduled_at": string | null,"segment": Json | null,"sent_at": string | null,"title": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "body"?: string | null,"channels"?: (string)[] | null,"created_by"?: string | null,"id"?: string | null,"recipient_count"?: number | null,"scheduled_at"?: string | null,"segment"?: Json | null,"sent_at"?: string | null,"title"?: string | null
                         }
                        Update: {
                           "body"?: string | null,"channels"?: (string)[] | null,"created_by"?: string | null,"id"?: string | null,"recipient_count"?: number | null,"scheduled_at"?: string | null,"segment"?: Json | null,"sent_at"?: string | null,"title"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"budget_alerts": {
                  Row: {
                    "campaign_id": string | null,"created_at": string | null,"kind": string | null,"utilization_pct": number | null
                  }
                  ComputedFields: never
                  Insert: {
                           "campaign_id"?: string | null,"created_at"?: string | null,"kind"?: string | null,"utilization_pct"?: number | null
                         }
                        Update: {
                           "campaign_id"?: string | null,"created_at"?: string | null,"kind"?: string | null,"utilization_pct"?: number | null
                         }
                        Relationships: [
                    
                  ]
                },"campaign_assets": {
                  Row: {
                    "audience": string | null,"campaign_id": string | null,"created_at": string | null,"id": string | null,"kind": string | null,"size_bytes": number | null,"storage_path": string | null,"url": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "audience"?: string | null,"campaign_id"?: string | null,"created_at"?: string | null,"id"?: string | null,"kind"?: string | null,"size_bytes"?: number | null,"storage_path"?: string | null,"url"?: string | null
                         }
                        Update: {
                           "audience"?: string | null,"campaign_id"?: string | null,"created_at"?: string | null,"id"?: string | null,"kind"?: string | null,"size_bytes"?: number | null,"storage_path"?: string | null,"url"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"campaign_invites": {
                  Row: {
                    "campaign_id": string | null,"created_at": string | null,"invited_by": string | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "campaign_id"?: string | null,"created_at"?: string | null,"invited_by"?: string | null,"user_id"?: string | null
                         }
                        Update: {
                           "campaign_id"?: string | null,"created_at"?: string | null,"invited_by"?: string | null,"user_id"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"campaigns": {
                  Row: {
                    "allow_video_reuse": boolean | null,"brief": string | null,"category_id": string | null,"clipper_quota": number | null,"created_at": string | null,"donts": (string)[] | null,"dos": (string)[] | null,"example_urls": (string)[] | null,"faq": Json | null,"fee_rule_id": string | null,"id": string | null,"is_template": boolean | null,"kyc_required": boolean | null,"max_clips_per_clipper": number | null,"max_duration_sec": number | null,"min_account_age_days": number | null,"min_duration_sec": number | null,"min_followers": number | null,"min_trust_score": number | null,"min_views": number | null,"org_id": string | null,"pinned_rank": number | null,"pinned_until": string | null,"platforms": ("tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x")[] | null,"required_hashtags": (string)[] | null,"required_links": (string)[] | null,"required_mentions": (string)[] | null,"review_mode": string | null,"service_mode": string | null,"slug": string | null,"sponsored_label": boolean | null,"start_at": string | null,"status": "draft"|"in_review"|"cancelled"|"scheduled"|"rejected"|"live"|"paused"|"tracking"|"exhausted"|"settling"|"settled" | null,"submit_deadline": string | null,"title": string | null,"type": string | null,"view_window_days": number | null,"visibility": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "allow_video_reuse"?: boolean | null,"brief"?: string | null,"category_id"?: string | null,"clipper_quota"?: number | null,"created_at"?: string | null,"donts"?: (string)[] | null,"dos"?: (string)[] | null,"example_urls"?: (string)[] | null,"faq"?: Json | null,"fee_rule_id"?: string | null,"id"?: string | null,"is_template"?: boolean | null,"kyc_required"?: boolean | null,"max_clips_per_clipper"?: number | null,"max_duration_sec"?: number | null,"min_account_age_days"?: number | null,"min_duration_sec"?: number | null,"min_followers"?: number | null,"min_trust_score"?: number | null,"min_views"?: number | null,"org_id"?: string | null,"pinned_rank"?: number | null,"pinned_until"?: string | null,"platforms"?: ("tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x")[] | null,"required_hashtags"?: (string)[] | null,"required_links"?: (string)[] | null,"required_mentions"?: (string)[] | null,"review_mode"?: string | null,"service_mode"?: string | null,"slug"?: string | null,"sponsored_label"?: boolean | null,"start_at"?: string | null,"status"?: "draft"|"in_review"|"cancelled"|"scheduled"|"rejected"|"live"|"paused"|"tracking"|"exhausted"|"settling"|"settled" | null,"submit_deadline"?: string | null,"title"?: string | null,"type"?: string | null,"view_window_days"?: number | null,"visibility"?: string | null
                         }
                        Update: {
                           "allow_video_reuse"?: boolean | null,"brief"?: string | null,"category_id"?: string | null,"clipper_quota"?: number | null,"created_at"?: string | null,"donts"?: (string)[] | null,"dos"?: (string)[] | null,"example_urls"?: (string)[] | null,"faq"?: Json | null,"fee_rule_id"?: string | null,"id"?: string | null,"is_template"?: boolean | null,"kyc_required"?: boolean | null,"max_clips_per_clipper"?: number | null,"max_duration_sec"?: number | null,"min_account_age_days"?: number | null,"min_duration_sec"?: number | null,"min_followers"?: number | null,"min_trust_score"?: number | null,"min_views"?: number | null,"org_id"?: string | null,"pinned_rank"?: number | null,"pinned_until"?: string | null,"platforms"?: ("tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x")[] | null,"required_hashtags"?: (string)[] | null,"required_links"?: (string)[] | null,"required_mentions"?: (string)[] | null,"review_mode"?: string | null,"service_mode"?: string | null,"slug"?: string | null,"sponsored_label"?: boolean | null,"start_at"?: string | null,"status"?: "draft"|"in_review"|"cancelled"|"scheduled"|"rejected"|"live"|"paused"|"tracking"|"exhausted"|"settling"|"settled" | null,"submit_deadline"?: string | null,"title"?: string | null,"type"?: string | null,"view_window_days"?: number | null,"visibility"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"categories": {
                  Row: {
                    "active": boolean | null,"id": string | null,"name_en": string | null,"name_id": string | null,"sort": number | null
                  }
                  ComputedFields: never
                  Insert: {
                           "active"?: boolean | null,"id"?: string | null,"name_en"?: string | null,"name_id"?: string | null,"sort"?: number | null
                         }
                        Update: {
                           "active"?: boolean | null,"id"?: string | null,"name_en"?: string | null,"name_id"?: string | null,"sort"?: number | null
                         }
                        Relationships: [
                    
                  ]
                },"claims": {
                  Row: {
                    "campaign_id": string | null,"created_at": string | null,"expires_at": string | null,"id": string | null,"status": "open"|"submitted"|"expired"|"released" | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "campaign_id"?: string | null,"created_at"?: string | null,"expires_at"?: string | null,"id"?: string | null,"status"?: "open"|"submitted"|"expired"|"released" | null,"user_id"?: string | null
                         }
                        Update: {
                           "campaign_id"?: string | null,"created_at"?: string | null,"expires_at"?: string | null,"id"?: string | null,"status"?: "open"|"submitted"|"expired"|"released" | null,"user_id"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"clip_earnings": {
                  Row: {
                    "amount": number | null,"demand": number | null,"pool_id": string | null,"released_at": string | null,"rule_id": string | null,"submission_id": string | null,"updated_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "amount"?: number | null,"demand"?: number | null,"pool_id"?: string | null,"released_at"?: string | null,"rule_id"?: string | null,"submission_id"?: string | null,"updated_at"?: string | null
                         }
                        Update: {
                           "amount"?: number | null,"demand"?: number | null,"pool_id"?: string | null,"released_at"?: string | null,"rule_id"?: string | null,"submission_id"?: string | null,"updated_at"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"fee_rules": {
                  Row: {
                    "admin_fee_pct": number | null,"clipper_fee_pct": number | null,"id": string | null,"instant_withdraw_fee": number | null,"mgmt_fee_pct": number | null,"scope": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "admin_fee_pct"?: number | null,"clipper_fee_pct"?: number | null,"id"?: string | null,"instant_withdraw_fee"?: number | null,"mgmt_fee_pct"?: number | null,"scope"?: string | null
                         }
                        Update: {
                           "admin_fee_pct"?: number | null,"clipper_fee_pct"?: number | null,"id"?: string | null,"instant_withdraw_fee"?: number | null,"mgmt_fee_pct"?: number | null,"scope"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"fraud_flags": {
                  Row: {
                    "created_at": string | null,"details": Json | null,"id": string | null,"resolved_at": string | null,"resolved_by": string | null,"score": number | null,"signal": string | null,"status": string | null,"target_id": string | null,"target_type": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "created_at"?: string | null,"details"?: Json | null,"id"?: string | null,"resolved_at"?: string | null,"resolved_by"?: string | null,"score"?: number | null,"signal"?: string | null,"status"?: string | null,"target_id"?: string | null,"target_type"?: string | null
                         }
                        Update: {
                           "created_at"?: string | null,"details"?: Json | null,"id"?: string | null,"resolved_at"?: string | null,"resolved_by"?: string | null,"score"?: number | null,"signal"?: string | null,"status"?: string | null,"target_id"?: string | null,"target_type"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"fulfillment_exports": {
                  Row: {
                    "file_ref": string | null,"pending": number | null,"reward_type_id": string | null,"rows": number | null
                  }
                  ComputedFields: never
                  Relationships: [
                    
                  ]
                },"fulfillments": {
                  Row: {
                    "amount": number | null,"attempts": number | null,"created_at": string | null,"delivered_at": string | null,"delivered_ref": string | null,"id": string | null,"recipient": Json | null,"reward_type_id": string | null,"status": "requested"|"on_hold"|"processing"|"cancelled"|"delivered"|"failed"|"returned" | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "amount"?: number | null,"attempts"?: number | null,"created_at"?: string | null,"delivered_at"?: string | null,"delivered_ref"?: string | null,"id"?: string | null,"recipient"?: Json | null,"reward_type_id"?: string | null,"status"?: "requested"|"on_hold"|"processing"|"cancelled"|"delivered"|"failed"|"returned" | null,"user_id"?: string | null
                         }
                        Update: {
                           "amount"?: number | null,"attempts"?: number | null,"created_at"?: string | null,"delivered_at"?: string | null,"delivered_ref"?: string | null,"id"?: string | null,"recipient"?: Json | null,"reward_type_id"?: string | null,"status"?: "requested"|"on_hold"|"processing"|"cancelled"|"delivered"|"failed"|"returned" | null,"user_id"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"invoices": {
                  Row: {
                    "admin_fee": number | null,"amount_due": number | null,"campaign_id": string | null,"credit_applied": number | null,"due_at": string | null,"faktur_no": string | null,"faktur_path": string | null,"fee_exempt": number | null,"id": string | null,"issued_at": string | null,"kind": string | null,"mgmt_fee": number | null,"number": string | null,"org_id": string | null,"paid_amount": number | null,"paid_at": string | null,"payment_channel": string | null,"pin_until": string | null,"pool_topups": Json | null,"service_fee": number | null,"status": string | null,"subtotal": number | null,"tax": number | null,"total": number | null
                  }
                  ComputedFields: never
                  Insert: {
                           "admin_fee"?: number | null,"amount_due"?: never,"campaign_id"?: string | null,"credit_applied"?: number | null,"due_at"?: string | null,"faktur_no"?: string | null,"faktur_path"?: string | null,"fee_exempt"?: number | null,"id"?: string | null,"issued_at"?: string | null,"kind"?: string | null,"mgmt_fee"?: number | null,"number"?: string | null,"org_id"?: string | null,"paid_amount"?: number | null,"paid_at"?: string | null,"payment_channel"?: string | null,"pin_until"?: string | null,"pool_topups"?: Json | null,"service_fee"?: number | null,"status"?: string | null,"subtotal"?: number | null,"tax"?: number | null,"total"?: number | null
                         }
                        Update: {
                           "admin_fee"?: number | null,"amount_due"?: never,"campaign_id"?: string | null,"credit_applied"?: number | null,"due_at"?: string | null,"faktur_no"?: string | null,"faktur_path"?: string | null,"fee_exempt"?: number | null,"id"?: string | null,"issued_at"?: string | null,"kind"?: string | null,"mgmt_fee"?: number | null,"number"?: string | null,"org_id"?: string | null,"paid_amount"?: number | null,"paid_at"?: string | null,"payment_channel"?: string | null,"pin_until"?: string | null,"pool_topups"?: Json | null,"service_fee"?: number | null,"status"?: string | null,"subtotal"?: number | null,"tax"?: number | null,"total"?: number | null
                         }
                        Relationships: [
                    
                  ]
                },"leaderboard": {
                  Row: {
                    "avatar_path": string | null,"campaign_id": string | null,"rank": number | null,"scope": string | null,"user_id": string | null,"username": string | null,"views": number | null,"week_start": string | null
                  }
                  ComputedFields: never
                  Relationships: [
                    
                  ]
                },"managed_briefs": {
                  Row: {
                    "campaign_id": string | null,"managed_brief": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "campaign_id"?: string | null,"managed_brief"?: string | null
                         }
                        Update: {
                           "campaign_id"?: string | null,"managed_brief"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"my_profile": {
                  Row: {
                    "avatar_path": string | null,"created_at": string | null,"display_name": string | null,"id": string | null,"status": "active"|"suspended"|"banned"|"closed" | null,"suspended_until": string | null,"trust_score": number | null,"username": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "avatar_path"?: string | null,"created_at"?: string | null,"display_name"?: string | null,"id"?: string | null,"status"?: "active"|"suspended"|"banned"|"closed" | null,"suspended_until"?: string | null,"trust_score"?: number | null,"username"?: string | null
                         }
                        Update: {
                           "avatar_path"?: string | null,"created_at"?: string | null,"display_name"?: string | null,"id"?: string | null,"status"?: "active"|"suspended"|"banned"|"closed" | null,"suspended_until"?: string | null,"trust_score"?: number | null,"username"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"notification_prefs": {
                  Row: {
                    "email_promotions": boolean | null,"updated_at": string | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "email_promotions"?: boolean | null,"updated_at"?: string | null,"user_id"?: string | null
                         }
                        Update: {
                           "email_promotions"?: boolean | null,"updated_at"?: string | null,"user_id"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"notifications": {
                  Row: {
                    "created_at": string | null,"event": string | null,"id": number | null,"payload": Json | null,"read_at": string | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "created_at"?: string | null,"event"?: string | null,"id"?: number | null,"payload"?: Json | null,"read_at"?: string | null,"user_id"?: string | null
                         }
                        Update: {
                           "created_at"?: string | null,"event"?: string | null,"id"?: number | null,"payload"?: Json | null,"read_at"?: string | null,"user_id"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"org_invites": {
                  Row: {
                    "accepted_at": string | null,"accepted_by": string | null,"created_at": string | null,"created_by": string | null,"expires_at": string | null,"id": string | null,"org_id": string | null,"role": "brand_owner"|"brand_manager"|"brand_finance"|"brand_viewer" | null
                  }
                  ComputedFields: never
                  Insert: {
                           "accepted_at"?: string | null,"accepted_by"?: string | null,"created_at"?: string | null,"created_by"?: string | null,"expires_at"?: string | null,"id"?: string | null,"org_id"?: string | null,"role"?: "brand_owner"|"brand_manager"|"brand_finance"|"brand_viewer" | null
                         }
                        Update: {
                           "accepted_at"?: string | null,"accepted_by"?: string | null,"created_at"?: string | null,"created_by"?: string | null,"expires_at"?: string | null,"id"?: string | null,"org_id"?: string | null,"role"?: "brand_owner"|"brand_manager"|"brand_finance"|"brand_viewer" | null
                         }
                        Relationships: [
                    
                  ]
                },"org_links": {
                  Row: {
                    "agency_org_id": string | null,"approved_at": string | null,"approved_by": string | null,"client_org_id": string | null,"created_at": string | null,"revoked_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "agency_org_id"?: string | null,"approved_at"?: string | null,"approved_by"?: string | null,"client_org_id"?: string | null,"created_at"?: string | null,"revoked_at"?: string | null
                         }
                        Update: {
                           "agency_org_id"?: string | null,"approved_at"?: string | null,"approved_by"?: string | null,"client_org_id"?: string | null,"created_at"?: string | null,"revoked_at"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"org_members": {
                  Row: {
                    "created_at": string | null,"org_id": string | null,"role": "brand_owner"|"brand_manager"|"brand_finance"|"brand_viewer" | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "created_at"?: string | null,"org_id"?: string | null,"role"?: "brand_owner"|"brand_manager"|"brand_finance"|"brand_viewer" | null,"user_id"?: string | null
                         }
                        Update: {
                           "created_at"?: string | null,"org_id"?: string | null,"role"?: "brand_owner"|"brand_manager"|"brand_finance"|"brand_viewer" | null,"user_id"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"org_refunds": {
                  Row: {
                    "amount": number | null,"bank_ref": string | null,"campaign_id": string | null,"created_at": string | null,"id": string | null,"org_id": string | null,"paid_at": string | null,"requested_by": string | null,"status": string | null,"transfer_fee": number | null
                  }
                  ComputedFields: never
                  Insert: {
                           "amount"?: number | null,"bank_ref"?: string | null,"campaign_id"?: string | null,"created_at"?: string | null,"id"?: string | null,"org_id"?: string | null,"paid_at"?: string | null,"requested_by"?: string | null,"status"?: string | null,"transfer_fee"?: number | null
                         }
                        Update: {
                           "amount"?: number | null,"bank_ref"?: string | null,"campaign_id"?: string | null,"created_at"?: string | null,"id"?: string | null,"org_id"?: string | null,"paid_at"?: string | null,"requested_by"?: string | null,"status"?: string | null,"transfer_fee"?: number | null
                         }
                        Relationships: [
                    
                  ]
                },"organizations": {
                  Row: {
                    "address": string | null,"created_at": string | null,"fee_rule_id": string | null,"id": string | null,"is_agency": boolean | null,"legal_name": string | null,"name": string | null,"npwp": string | null,"org_type": string | null,"status": "pending_verification"|"verified"|"suspended" | null,"updated_at": string | null,"verified_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "address"?: string | null,"created_at"?: string | null,"fee_rule_id"?: string | null,"id"?: string | null,"is_agency"?: boolean | null,"legal_name"?: string | null,"name"?: string | null,"npwp"?: string | null,"org_type"?: string | null,"status"?: "pending_verification"|"verified"|"suspended" | null,"updated_at"?: string | null,"verified_at"?: string | null
                         }
                        Update: {
                           "address"?: string | null,"created_at"?: string | null,"fee_rule_id"?: string | null,"id"?: string | null,"is_agency"?: boolean | null,"legal_name"?: string | null,"name"?: string | null,"npwp"?: string | null,"org_type"?: string | null,"status"?: "pending_verification"|"verified"|"suspended" | null,"updated_at"?: string | null,"verified_at"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"payout_batches": {
                  Row: {
                    "approved_by": string | null,"count": number | null,"created_at": string | null,"created_by": string | null,"cutoff_at": string | null,"executed_at": string | null,"id": string | null,"status": string | null,"total": number | null
                  }
                  ComputedFields: never
                  Insert: {
                           "approved_by"?: string | null,"count"?: number | null,"created_at"?: string | null,"created_by"?: string | null,"cutoff_at"?: string | null,"executed_at"?: string | null,"id"?: string | null,"status"?: string | null,"total"?: number | null
                         }
                        Update: {
                           "approved_by"?: string | null,"count"?: number | null,"created_at"?: string | null,"created_by"?: string | null,"cutoff_at"?: string | null,"executed_at"?: string | null,"id"?: string | null,"status"?: string | null,"total"?: number | null
                         }
                        Relationships: [
                    
                  ]
                },"payouts": {
                  Row: {
                    "amount": number | null,"bank_ref": string | null,"batch_id": string | null,"channel": string | null,"created_at": string | null,"fee": number | null,"hold_reason": string | null,"id": string | null,"last_error": string | null,"method_id": string | null,"paid_at": string | null,"provider_ref": string | null,"status": "requested"|"on_hold"|"processing"|"cancelled"|"paid"|"failed"|"returned" | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "amount"?: number | null,"bank_ref"?: string | null,"batch_id"?: string | null,"channel"?: string | null,"created_at"?: string | null,"fee"?: number | null,"hold_reason"?: string | null,"id"?: string | null,"last_error"?: string | null,"method_id"?: string | null,"paid_at"?: string | null,"provider_ref"?: string | null,"status"?: "requested"|"on_hold"|"processing"|"cancelled"|"paid"|"failed"|"returned" | null,"user_id"?: string | null
                         }
                        Update: {
                           "amount"?: number | null,"bank_ref"?: string | null,"batch_id"?: string | null,"channel"?: string | null,"created_at"?: string | null,"fee"?: number | null,"hold_reason"?: string | null,"id"?: string | null,"last_error"?: string | null,"method_id"?: string | null,"paid_at"?: string | null,"provider_ref"?: string | null,"status"?: "requested"|"on_hold"|"processing"|"cancelled"|"paid"|"failed"|"returned" | null,"user_id"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"profiles": {
                  Row: {
                    "avatar_path": string | null,"created_at": string | null,"display_name": string | null,"id": string | null,"username": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "avatar_path"?: string | null,"created_at"?: string | null,"display_name"?: string | null,"id"?: string | null,"username"?: string | null
                         }
                        Update: {
                           "avatar_path"?: string | null,"created_at"?: string | null,"display_name"?: string | null,"id"?: string | null,"username"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"rate_rules": {
                  Row: {
                    "campaign_id": string | null,"effective_from": string | null,"effective_to": string | null,"id": string | null,"kind": string | null,"params": Json | null,"platform": "tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x" | null,"pool_id": string | null,"reward_type_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "campaign_id"?: string | null,"effective_from"?: string | null,"effective_to"?: string | null,"id"?: string | null,"kind"?: string | null,"params"?: Json | null,"platform"?: "tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x" | null,"pool_id"?: string | null,"reward_type_id"?: string | null
                         }
                        Update: {
                           "campaign_id"?: string | null,"effective_from"?: string | null,"effective_to"?: string | null,"id"?: string | null,"kind"?: string | null,"params"?: Json | null,"platform"?: "tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x" | null,"pool_id"?: string | null,"reward_type_id"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"referrals": {
                  Row: {
                    "bonus_until": string | null,"created_at": string | null,"qualified_at": string | null,"referred_id": string | null,"referred_username": string | null
                  }
                  ComputedFields: never
                  Relationships: [
                    
                  ]
                },"report_links": {
                  Row: {
                    "campaign_id": string | null,"created_at": string | null,"created_by": string | null,"expires_at": string | null,"id": string | null,"revoked_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "campaign_id"?: string | null,"created_at"?: string | null,"created_by"?: string | null,"expires_at"?: string | null,"id"?: string | null,"revoked_at"?: string | null
                         }
                        Update: {
                           "campaign_id"?: string | null,"created_at"?: string | null,"created_by"?: string | null,"expires_at"?: string | null,"id"?: string | null,"revoked_at"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"review_decisions": {
                  Row: {
                    "actor_id": string | null,"created_at": string | null,"decision": string | null,"id": number | null,"message": string | null,"reason_code": string | null,"target_id": string | null,"target_type": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "actor_id"?: string | null,"created_at"?: string | null,"decision"?: string | null,"id"?: number | null,"message"?: string | null,"reason_code"?: string | null,"target_id"?: string | null,"target_type"?: string | null
                         }
                        Update: {
                           "actor_id"?: string | null,"created_at"?: string | null,"decision"?: string | null,"id"?: number | null,"message"?: string | null,"reason_code"?: string | null,"target_id"?: string | null,"target_type"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"reward_codes": {
                  Row: {
                    "assigned_at": string | null,"code": string | null,"created_at": string | null,"fulfillment_id": string | null,"id": string | null,"reward_type_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "assigned_at"?: string | null,"code"?: string | null,"created_at"?: string | null,"fulfillment_id"?: string | null,"id"?: string | null,"reward_type_id"?: string | null
                         }
                        Update: {
                           "assigned_at"?: string | null,"code"?: string | null,"created_at"?: string | null,"fulfillment_id"?: string | null,"id"?: string | null,"reward_type_id"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"reward_pools": {
                  Row: {
                    "allocated": number | null,"campaign_id": string | null,"id": string | null,"max_per_clip": number | null,"remaining": number | null,"reward_type_id": string | null,"total": number | null
                  }
                  ComputedFields: never
                  Insert: {
                           "allocated"?: number | null,"campaign_id"?: string | null,"id"?: string | null,"max_per_clip"?: number | null,"remaining"?: never,"reward_type_id"?: string | null,"total"?: number | null
                         }
                        Update: {
                           "allocated"?: number | null,"campaign_id"?: string | null,"id"?: string | null,"max_per_clip"?: number | null,"remaining"?: never,"reward_type_id"?: string | null,"total"?: number | null
                         }
                        Relationships: [
                    
                  ]
                },"reward_types": {
                  Row: {
                    "code": string | null,"decimals": number | null,"fulfillment": string | null,"id": string | null,"idr_value_per_unit": number | null,"kind": string | null,"name": string | null,"owner_org_id": string | null,"recipient_schema": Json | null,"stock": number | null,"unit_label": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "code"?: string | null,"decimals"?: number | null,"fulfillment"?: string | null,"id"?: string | null,"idr_value_per_unit"?: number | null,"kind"?: string | null,"name"?: string | null,"owner_org_id"?: string | null,"recipient_schema"?: Json | null,"stock"?: number | null,"unit_label"?: string | null
                         }
                        Update: {
                           "code"?: string | null,"decimals"?: number | null,"fulfillment"?: string | null,"id"?: string | null,"idr_value_per_unit"?: number | null,"kind"?: string | null,"name"?: string | null,"owner_org_id"?: string | null,"recipient_schema"?: Json | null,"stock"?: number | null,"unit_label"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"score_events": {
                  Row: {
                    "created_at": string | null,"delta": number | null,"id": number | null,"reason": string | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "created_at"?: string | null,"delta"?: number | null,"id"?: number | null,"reason"?: string | null,"user_id"?: string | null
                         }
                        Update: {
                           "created_at"?: string | null,"delta"?: number | null,"id"?: number | null,"reason"?: string | null,"user_id"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"settings": {
                  Row: {
                    "key": string | null,"updated_at": string | null,"value": Json | null
                  }
                  ComputedFields: never
                  Insert: {
                           "key"?: string | null,"updated_at"?: string | null,"value"?: Json | null
                         }
                        Update: {
                           "key"?: string | null,"updated_at"?: string | null,"value"?: Json | null
                         }
                        Relationships: [
                    
                  ]
                },"social_accounts": {
                  Row: {
                    "created_at": string | null,"external_id": string | null,"followers": number | null,"handle": string | null,"id": string | null,"platform": "tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x" | null,"platform_created_at": string | null,"status": string | null,"user_id": string | null,"verified_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "created_at"?: string | null,"external_id"?: string | null,"followers"?: number | null,"handle"?: string | null,"id"?: string | null,"platform"?: "tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x" | null,"platform_created_at"?: string | null,"status"?: string | null,"user_id"?: string | null,"verified_at"?: string | null
                         }
                        Update: {
                           "created_at"?: string | null,"external_id"?: string | null,"followers"?: number | null,"handle"?: string | null,"id"?: string | null,"platform"?: "tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x" | null,"platform_created_at"?: string | null,"status"?: string | null,"user_id"?: string | null,"verified_at"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"submissions": {
                  Row: {
                    "campaign_id": string | null,"claim_id": string | null,"counted_views": number | null,"created_at": string | null,"id": string | null,"last_snapshot_at": string | null,"last_views": number | null,"locked_at": string | null,"platform": "tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x" | null,"post_id": string | null,"posted_at": string | null,"social_account_id": string | null,"status": "validating"|"in_review"|"tracking"|"rejected"|"flagged"|"forfeited"|"locked"|"appealed"|"settled"|"rejected_final" | null,"url": string | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "campaign_id"?: string | null,"claim_id"?: string | null,"counted_views"?: number | null,"created_at"?: string | null,"id"?: string | null,"last_snapshot_at"?: string | null,"last_views"?: number | null,"locked_at"?: string | null,"platform"?: "tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x" | null,"post_id"?: string | null,"posted_at"?: string | null,"social_account_id"?: string | null,"status"?: "validating"|"in_review"|"tracking"|"rejected"|"flagged"|"forfeited"|"locked"|"appealed"|"settled"|"rejected_final" | null,"url"?: string | null,"user_id"?: string | null
                         }
                        Update: {
                           "campaign_id"?: string | null,"claim_id"?: string | null,"counted_views"?: number | null,"created_at"?: string | null,"id"?: string | null,"last_snapshot_at"?: string | null,"last_views"?: number | null,"locked_at"?: string | null,"platform"?: "tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x" | null,"post_id"?: string | null,"posted_at"?: string | null,"social_account_id"?: string | null,"status"?: "validating"|"in_review"|"tracking"|"rejected"|"flagged"|"forfeited"|"locked"|"appealed"|"settled"|"rejected_final" | null,"url"?: string | null,"user_id"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"view_snapshots": {
                  Row: {
                    "comments": number | null,"id": number | null,"is_final": boolean | null,"likes": number | null,"shares": number | null,"submission_id": string | null,"taken_at": string | null,"views": number | null
                  }
                  ComputedFields: never
                  Insert: {
                           "comments"?: number | null,"id"?: number | null,"is_final"?: boolean | null,"likes"?: number | null,"shares"?: number | null,"submission_id"?: string | null,"taken_at"?: string | null,"views"?: number | null
                         }
                        Update: {
                           "comments"?: number | null,"id"?: number | null,"is_final"?: boolean | null,"likes"?: number | null,"shares"?: number | null,"submission_id"?: string | null,"taken_at"?: string | null,"views"?: number | null
                         }
                        Relationships: [
                    
                  ]
                },"wallet_balances": {
                  Row: {
                    "amount": number | null,"reward_type_id": string | null,"state": "pending"|"available"|"withdrawn" | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Relationships: [
                    
                  ]
                },"wallet_entries": {
                  Row: {
                    "amount": number | null,"created_at": string | null,"id": number | null,"ref_id": string | null,"ref_type": string | null,"reward_type_id": string | null,"state": "pending"|"available"|"withdrawn" | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Relationships: [
                    
                  ]
                }
          }
          Functions: {
            "accept_org_invite":
{ Args: { "p_token": string }; Returns: string
                           },
"admin_overview":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"appeal_submission":
{ Args: { "p_message": string,"p_submission": string }; Returns: undefined
                           },
"approve_payout_batch":
{ Args: { "p_batch": string }; Returns: undefined
                           },
"approve_refund":
{ Args: { "p_refund": string }; Returns: undefined
                           },
"attach_faktur":
{ Args: { "p_faktur_no": string,"p_invoice": string,"p_path": string }; Returns: undefined
                           },
"bank_issues":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"bridge_alert_notified":
{ Args: { "p_alert": number }; Returns: undefined
                           },
"bridge_attach_export":
{ Args: { "p_batch": string,"p_exported": (string)[],"p_file_ref": string,"p_held": Json }; Returns: undefined
                           },
"bridge_attach_fulfillment_export":
{ Args: { "p_exported": (string)[],"p_file_ref": string,"p_reward_type": string }; Returns: undefined
                           },
"bridge_attach_proof":
{ Args: { "p_id": string,"p_proof_ref": string,"p_target": string }; Returns: undefined
                           },
"bridge_close_account":
{ Args: { "p_user": string }; Returns: Json
                           },
"bridge_collect_ids":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"bridge_fulfillment_export":
{ Args: { "p_reward_type": string }; Returns: {
              "amount": number,"id": string,"recipient": Json,"recipient_ref": string,"user_id": string
            }[]
                           },
"bridge_fulfillment_export_accepted":
{ Args: { "p_file_ref": string,"p_reward_type": string }; Returns: boolean
                           },
"bridge_get_batch":
{ Args: { "p_batch": string }; Returns: Json
                           },
"bridge_get_payout":
{ Args: { "p_payout": string }; Returns: Json
                           },
"bridge_mark_instant":
{ Args: { "p_error": string,"p_payout": string,"p_provider_ref": string,"p_status": string }; Returns: undefined
                           },
"bridge_pph21":
{ Args: { "p_from": string,"p_to": string }; Returns: {
              "gross": number,"user_id": string
            }[]
                           },
"bridge_raise_fraud_flag":
{ Args: { "p_details": Json,"p_score": number,"p_signal": string,"p_target_id": string,"p_target_type": string }; Returns: string
                           },
"bridge_report_orphans":
{ Args: { "p_missing": Json }; Returns: undefined
                           },
"buy_pin":
{ Args: { "p_campaign": string,"p_days": number }; Returns: string
                           },
"campaign_detail":
{ Args: { "p_campaign": string }; Returns: Json
                           },
"campaign_stats":
{ Args: { "p_campaign": string }; Returns: Json
                           },
"cancel_fulfillment":
{ Args: { "p_confirmed_not_delivered"?: boolean,"p_fulfillment": string,"p_reason": string }; Returns: undefined
                           },
"cancel_payout":
{ Args: { "p_payout": string,"p_reason": string }; Returns: undefined
                           },
"claim_campaign":
{ Args: { "p_campaign": string }; Returns: Database["api"]['Views']["claims"]['Row']
                          SetofOptions: {
        from: "*"
        to: "claims"
        isOneToOne: true
        isSetofReturn: false
      } },
"confirm_invoice_payment":
{ Args: { "p_amount": number,"p_channel": string,"p_invoice": string,"p_paid_at": string,"p_ref": string }; Returns: undefined
                           },
"control_campaign":
{ Args: { "p_action": string,"p_campaign": string,"p_params"?: Json }; Returns: undefined
                           },
"create_org":
{ Args: { "p_address"?: string,"p_is_agency"?: boolean,"p_legal_name"?: string,"p_name": string,"p_npwp"?: string,"p_org_type": string }; Returns: string
                           },
"create_org_invite":
{ Args: { "p_org": string,"p_role": string }; Returns: string
                           },
"create_payout_batch":
{ Args: { "p_cutoff": string }; Returns: string
                           },
"create_report_link":
{ Args: { "p_campaign": string,"p_days"?: number }; Returns: string
                           },
"duplicate_campaign":
{ Args: { "p_as_template"?: boolean,"p_campaign": string }; Returns: string
                           },
"ensure_profile":
{ Args: { "p_avatar_path"?: string,"p_display_name": string,"p_referral_code"?: string,"p_username": string }; Returns: {
              "created": boolean,"display_name": string,"id": string,"username": string
            }[]
                           },
"hold_payout":
{ Args: { "p_payout": string,"p_reason": string }; Returns: undefined
                           },
"import_bank_lines":
{ Args: { "p_lines": Json }; Returns: Json
                           },
"invite_preview":
{ Args: { "p_token": string }; Returns: {
              "expired": boolean,"is_agency": boolean,"org_name": string,"role": string,"used": boolean
            }[]
                           },
"invite_to_campaign":
{ Args: { "p_campaign": string,"p_usernames": (string)[] }; Returns: number
                           },
"link_agency":
{ Args: { "p_action": string,"p_agency": string,"p_client": string }; Returns: undefined
                           },
"list_campaigns":
{ Args: { "p_cursor"?: string,"p_filters"?: Json }; Returns: {
              "brand_name": string,"brand_verified": boolean,"budget_idr": number,"category_id": string,"cover_path": string,"cta_reason": string,"cta_state": string,"est_remaining_views": Json,"id": string,"is_new": boolean,"is_pinned": boolean,"next_cursor": string,"pinned_rank": number,"platforms": ("tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x")[],"rates": Json,"remaining_idr": number,"slug": string,"start_at": string,"status": "draft"|"in_review"|"cancelled"|"scheduled"|"rejected"|"live"|"paused"|"tracking"|"exhausted"|"settling"|"settled","submit_deadline": string,"title": string,"type": string,"visibility": string
            }[]
                           },
"manage_org":
{ Args: { "p_action": string,"p_org": string,"p_params"?: Json }; Returns: undefined
                           },
"manage_team":
{ Args: { "p_action": string,"p_org": string,"p_role"?: string,"p_target": string }; Returns: undefined
                           },
"manage_user":
{ Args: { "p_action": string,"p_params"?: Json,"p_user": string }; Returns: undefined
                           },
"mark_batch_paid":
{ Args: { "p_batch": string,"p_results": Json }; Returns: undefined
                           },
"mark_fulfillment_delivered":
{ Args: { "p_fulfillment": string,"p_ref": string }; Returns: undefined
                           },
"missing_brief_tags":
{ Args: { "p_campaign": string,"p_caption": string }; Returns: (string)[]
                           },
"my_clip_terms":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"my_referral_code":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"my_stats":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"org_credit":
{ Args: { "p_org": string }; Returns: Json
                           },
"pay_invoice_with_credit":
{ Args: { "p_amount"?: number,"p_invoice": string }; Returns: Json
                           },
"record_review":
{ Args: { "p_decision": string,"p_message"?: string,"p_note"?: string,"p_reason"?: string,"p_target_id": string,"p_target_type": string }; Returns: undefined
                           },
"release_payout":
{ Args: { "p_note": string,"p_payout": string }; Returns: undefined
                           },
"report_by_token":
{ Args: { "p_token": string }; Returns: Json
                           },
"request_fulfillment":
{ Args: { "p_amount": number,"p_idempotency": string,"p_recipient": Json,"p_recipient_ref": string,"p_reward_type": string }; Returns: Database["api"]['Views']["fulfillments"]['Row']
                          SetofOptions: {
        from: "*"
        to: "fulfillments"
        isOneToOne: true
        isSetofReturn: false
      } },
"request_payout":
{ Args: { "p_amount": number,"p_channel": string,"p_idempotency": string,"p_method": string }; Returns: Database["api"]['Views']["payouts"]['Row']
                          SetofOptions: {
        from: "*"
        to: "payouts"
        isOneToOne: true
        isSetofReturn: false
      } },
"request_refund":
{ Args: { "p_amount": number,"p_campaign": string,"p_idempotency": string,"p_mode": string,"p_org": string }; Returns: string
                           },
"resolve_alert":
{ Args: { "p_id": number }; Returns: undefined
                           },
"resolve_bank_line":
{ Args: { "p_id": number,"p_note": string }; Returns: undefined
                           },
"resolve_fraud_flag":
{ Args: { "p_action": string,"p_flag": string,"p_note": string }; Returns: undefined
                           },
"revoke_report_link":
{ Args: { "p_link": string }; Returns: undefined
                           },
"save_campaign":
{ Args: { "p_campaign": Json,"p_submit"?: boolean }; Returns: string
                           },
"save_reward_type":
{ Args: { "p": Json }; Returns: string
                           },
"send_broadcast":
{ Args: { "p_body": string,"p_channels"?: (string)[],"p_scheduled_at"?: string,"p_segment"?: Json,"p_title": string }; Returns: string
                           },
"set_bank_ref":
{ Args: { "p_id": string,"p_note"?: string,"p_ref": string,"p_target": string }; Returns: Json
                           },
"store_social_token":
{ Args: { "p_account_id": string,"p_token": string }; Returns: string
                           },
"update_config":
{ Args: { "p_key": string,"p_value": Json }; Returns: undefined
                           },
"update_org":
{ Args: { "p_address"?: string,"p_legal_name"?: string,"p_name": string,"p_npwp"?: string,"p_org": string }; Returns: undefined
                           },
"upload_reward_codes":
{ Args: { "p_codes": (string)[],"p_reward_type": string }; Returns: number
                           },
"worker_account_status":
{ Args: { "p_account": string,"p_status": string }; Returns: undefined
                           },
"worker_account_token":
{ Args: { "p_account": string }; Returns: Json
                           },
"worker_accounts_to_refresh":
{ Args: { "p_within": string }; Returns: {
              "account_id": string,"platform": "tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x","token": string
            }[]
                           },
"worker_ack":
{ Args: { "p_msg_id": number,"p_queue": string }; Returns: undefined
                           },
"worker_assign_code":
{ Args: { "p_fulfillment": string }; Returns: string
                           },
"worker_create_submission":
{ Args: { "p_account": string,"p_caption": string,"p_claim": string,"p_cover_hash"?: number,"p_duration_sec": number,"p_post_id": string,"p_posted_at": string,"p_url": string,"p_user": string }; Returns: Json
                           },
"worker_defer":
{ Args: { "p_submission": string,"p_until": string }; Returns: undefined
                           },
"worker_dequeue":
{ Args: { "p_qty"?: number,"p_queue": string,"p_vt_seconds"?: number }; Returns: {
              "message": Json,"msg_id": number,"read_ct": number
            }[]
                           },
"worker_fulfillment_result":
{ Args: { "p_error": string,"p_fulfillment": string,"p_ok": boolean,"p_ref": string }; Returns: undefined
                           },
"worker_fulfillments_due":
{ Args: { "p_limit": number }; Returns: {
              "amount": number,"attempts": number,"fulfillment": string,"id": string,"recipient": Json,"reward_type_id": string,"user_id": string,"webhook_secret": string,"webhook_url": string
            }[]
                           },
"worker_notification":
{ Args: { "p_id": number }; Returns: Json
                           },
"worker_post_gone":
{ Args: { "p_reason": string,"p_submission": string }; Returns: undefined
                           },
"worker_record_snapshot":
{ Args: { "p_caption": string,"p_comments": number,"p_extra"?: Json,"p_likes": number,"p_raw": Json,"p_shares": number,"p_submission": string,"p_views": number }; Returns: Json
                           },
"worker_retry_later":
{ Args: { "p_msg_id": number,"p_queue": string,"p_seconds": number,"p_submission"?: string }; Returns: undefined
                           },
"worker_submission_context":
{ Args: { "p_submission": string }; Returns: Json
                           },
"worker_unsubscribe":
{ Args: { "p_user": string }; Returns: undefined
                           },
"worker_upsert_social_account":
{ Args: { "p_external_id": string,"p_followers": number,"p_handle": string,"p_platform": string,"p_platform_created_at": string,"p_token": string,"p_user": string }; Returns: string
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "api": {
          Enums: {
            
          }
        }
} as const
