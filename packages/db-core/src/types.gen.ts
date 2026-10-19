
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "api": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            "audit_logs": {
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
                    "allow_video_reuse": boolean | null,"brief": string | null,"category_id": string | null,"clipper_quota": number | null,"created_at": string | null,"donts": (string)[] | null,"dos": (string)[] | null,"example_urls": (string)[] | null,"faq": Json | null,"id": string | null,"is_template": boolean | null,"kyc_required": boolean | null,"max_clips_per_clipper": number | null,"max_duration_sec": number | null,"min_account_age_days": number | null,"min_duration_sec": number | null,"min_followers": number | null,"min_trust_score": number | null,"min_views": number | null,"org_id": string | null,"pinned_rank": number | null,"pinned_until": string | null,"platforms": ("tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x")[] | null,"required_hashtags": (string)[] | null,"required_links": (string)[] | null,"required_mentions": (string)[] | null,"review_mode": string | null,"service_mode": string | null,"slug": string | null,"sponsored_label": boolean | null,"start_at": string | null,"status": "draft"|"in_review"|"cancelled"|"scheduled"|"rejected"|"live"|"paused"|"tracking"|"exhausted"|"settling"|"settled" | null,"submit_deadline": string | null,"title": string | null,"type": string | null,"view_window_days": number | null,"visibility": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "allow_video_reuse"?: boolean | null,"brief"?: string | null,"category_id"?: string | null,"clipper_quota"?: number | null,"created_at"?: string | null,"donts"?: (string)[] | null,"dos"?: (string)[] | null,"example_urls"?: (string)[] | null,"faq"?: Json | null,"id"?: string | null,"is_template"?: boolean | null,"kyc_required"?: boolean | null,"max_clips_per_clipper"?: number | null,"max_duration_sec"?: number | null,"min_account_age_days"?: number | null,"min_duration_sec"?: number | null,"min_followers"?: number | null,"min_trust_score"?: number | null,"min_views"?: number | null,"org_id"?: string | null,"pinned_rank"?: number | null,"pinned_until"?: string | null,"platforms"?: ("tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x")[] | null,"required_hashtags"?: (string)[] | null,"required_links"?: (string)[] | null,"required_mentions"?: (string)[] | null,"review_mode"?: string | null,"service_mode"?: string | null,"slug"?: string | null,"sponsored_label"?: boolean | null,"start_at"?: string | null,"status"?: "draft"|"in_review"|"cancelled"|"scheduled"|"rejected"|"live"|"paused"|"tracking"|"exhausted"|"settling"|"settled" | null,"submit_deadline"?: string | null,"title"?: string | null,"type"?: string | null,"view_window_days"?: number | null,"visibility"?: string | null
                         }
                        Update: {
                           "allow_video_reuse"?: boolean | null,"brief"?: string | null,"category_id"?: string | null,"clipper_quota"?: number | null,"created_at"?: string | null,"donts"?: (string)[] | null,"dos"?: (string)[] | null,"example_urls"?: (string)[] | null,"faq"?: Json | null,"id"?: string | null,"is_template"?: boolean | null,"kyc_required"?: boolean | null,"max_clips_per_clipper"?: number | null,"max_duration_sec"?: number | null,"min_account_age_days"?: number | null,"min_duration_sec"?: number | null,"min_followers"?: number | null,"min_trust_score"?: number | null,"min_views"?: number | null,"org_id"?: string | null,"pinned_rank"?: number | null,"pinned_until"?: string | null,"platforms"?: ("tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x")[] | null,"required_hashtags"?: (string)[] | null,"required_links"?: (string)[] | null,"required_mentions"?: (string)[] | null,"review_mode"?: string | null,"service_mode"?: string | null,"slug"?: string | null,"sponsored_label"?: boolean | null,"start_at"?: string | null,"status"?: "draft"|"in_review"|"cancelled"|"scheduled"|"rejected"|"live"|"paused"|"tracking"|"exhausted"|"settling"|"settled" | null,"submit_deadline"?: string | null,"title"?: string | null,"type"?: string | null,"view_window_days"?: number | null,"visibility"?: string | null
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
                    "admin_fee": number | null,"campaign_id": string | null,"due_at": string | null,"faktur_no": string | null,"id": string | null,"issued_at": string | null,"kind": string | null,"mgmt_fee": number | null,"number": string | null,"org_id": string | null,"paid_amount": number | null,"paid_at": string | null,"payment_channel": string | null,"pin_until": string | null,"service_fee": number | null,"status": string | null,"subtotal": number | null,"tax": number | null,"total": number | null
                  }
                  ComputedFields: never
                  Insert: {
                           "admin_fee"?: number | null,"campaign_id"?: string | null,"due_at"?: string | null,"faktur_no"?: string | null,"id"?: string | null,"issued_at"?: string | null,"kind"?: string | null,"mgmt_fee"?: number | null,"number"?: string | null,"org_id"?: string | null,"paid_amount"?: number | null,"paid_at"?: string | null,"payment_channel"?: string | null,"pin_until"?: string | null,"service_fee"?: number | null,"status"?: string | null,"subtotal"?: number | null,"tax"?: number | null,"total"?: number | null
                         }
                        Update: {
                           "admin_fee"?: number | null,"campaign_id"?: string | null,"due_at"?: string | null,"faktur_no"?: string | null,"id"?: string | null,"issued_at"?: string | null,"kind"?: string | null,"mgmt_fee"?: number | null,"number"?: string | null,"org_id"?: string | null,"paid_amount"?: number | null,"paid_at"?: string | null,"payment_channel"?: string | null,"pin_until"?: string | null,"service_fee"?: number | null,"status"?: string | null,"subtotal"?: number | null,"tax"?: number | null,"total"?: number | null
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
                    "amount": number | null,"campaign_id": string | null,"created_at": string | null,"id": string | null,"org_id": string | null,"paid_at": string | null,"status": string | null,"transfer_fee": number | null
                  }
                  ComputedFields: never
                  Insert: {
                           "amount"?: number | null,"campaign_id"?: string | null,"created_at"?: string | null,"id"?: string | null,"org_id"?: string | null,"paid_at"?: string | null,"status"?: string | null,"transfer_fee"?: number | null
                         }
                        Update: {
                           "amount"?: number | null,"campaign_id"?: string | null,"created_at"?: string | null,"id"?: string | null,"org_id"?: string | null,"paid_at"?: string | null,"status"?: string | null,"transfer_fee"?: number | null
                         }
                        Relationships: [
                    
                  ]
                },"organizations": {
                  Row: {
                    "address": string | null,"created_at": string | null,"id": string | null,"is_agency": boolean | null,"legal_name": string | null,"name": string | null,"npwp": string | null,"org_type": string | null,"status": "pending_verification"|"verified"|"suspended" | null,"verified_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "address"?: string | null,"created_at"?: string | null,"id"?: string | null,"is_agency"?: boolean | null,"legal_name"?: string | null,"name"?: string | null,"npwp"?: string | null,"org_type"?: string | null,"status"?: "pending_verification"|"verified"|"suspended" | null,"verified_at"?: string | null
                         }
                        Update: {
                           "address"?: string | null,"created_at"?: string | null,"id"?: string | null,"is_agency"?: boolean | null,"legal_name"?: string | null,"name"?: string | null,"npwp"?: string | null,"org_type"?: string | null,"status"?: "pending_verification"|"verified"|"suspended" | null,"verified_at"?: string | null
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
                    "amount": number | null,"batch_id": string | null,"channel": string | null,"created_at": string | null,"fee": number | null,"hold_reason": string | null,"id": string | null,"method_id": string | null,"paid_at": string | null,"status": "requested"|"on_hold"|"processing"|"cancelled"|"paid"|"failed"|"returned" | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "amount"?: number | null,"batch_id"?: string | null,"channel"?: string | null,"created_at"?: string | null,"fee"?: number | null,"hold_reason"?: string | null,"id"?: string | null,"method_id"?: string | null,"paid_at"?: string | null,"status"?: "requested"|"on_hold"|"processing"|"cancelled"|"paid"|"failed"|"returned" | null,"user_id"?: string | null
                         }
                        Update: {
                           "amount"?: number | null,"batch_id"?: string | null,"channel"?: string | null,"created_at"?: string | null,"fee"?: number | null,"hold_reason"?: string | null,"id"?: string | null,"method_id"?: string | null,"paid_at"?: string | null,"status"?: "requested"|"on_hold"|"processing"|"cancelled"|"paid"|"failed"|"returned" | null,"user_id"?: string | null
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
                    "campaign_id": string | null,"claim_id": string | null,"counted_views": number | null,"created_at": string | null,"id": string | null,"last_snapshot_at": string | null,"locked_at": string | null,"platform": "tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x" | null,"post_id": string | null,"posted_at": string | null,"social_account_id": string | null,"status": "validating"|"in_review"|"tracking"|"rejected"|"flagged"|"forfeited"|"locked"|"appealed"|"settled"|"rejected_final" | null,"url": string | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "campaign_id"?: string | null,"claim_id"?: string | null,"counted_views"?: number | null,"created_at"?: string | null,"id"?: string | null,"last_snapshot_at"?: string | null,"locked_at"?: string | null,"platform"?: "tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x" | null,"post_id"?: string | null,"posted_at"?: string | null,"social_account_id"?: string | null,"status"?: "validating"|"in_review"|"tracking"|"rejected"|"flagged"|"forfeited"|"locked"|"appealed"|"settled"|"rejected_final" | null,"url"?: string | null,"user_id"?: string | null
                         }
                        Update: {
                           "campaign_id"?: string | null,"claim_id"?: string | null,"counted_views"?: number | null,"created_at"?: string | null,"id"?: string | null,"last_snapshot_at"?: string | null,"locked_at"?: string | null,"platform"?: "tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x" | null,"post_id"?: string | null,"posted_at"?: string | null,"social_account_id"?: string | null,"status"?: "validating"|"in_review"|"tracking"|"rejected"|"flagged"|"forfeited"|"locked"|"appealed"|"settled"|"rejected_final" | null,"url"?: string | null,"user_id"?: string | null
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
            "create_report_link":
{ Args: { "p_campaign": string,"p_days"?: number }; Returns: string
                           },
"ensure_profile":
{ Args: { "p_display_name": string,"p_referral_code"?: string,"p_username": string }; Returns: {
              "created": boolean,"display_name": string,"id": string,"username": string
            }[]
                           },
"missing_brief_tags":
{ Args: { "p_campaign": string,"p_caption": string }; Returns: (string)[]
                           },
"my_referral_code":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"report_by_token":
{ Args: { "p_token": string }; Returns: Json
                           },
"revoke_report_link":
{ Args: { "p_link": string }; Returns: undefined
                           },
"store_social_token":
{ Args: { "p_account_id": string,"p_token": string }; Returns: string
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
