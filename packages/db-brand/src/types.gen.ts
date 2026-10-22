
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "api": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            "campaign_assets": {
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
                    "allow_video_reuse": boolean | null,"brief": string | null,"category_id": string | null,"clipper_quota": number | null,"content_version": number | null,"created_at": string | null,"created_by": string | null,"donts": (string)[] | null,"dos": (string)[] | null,"example_urls": (string)[] | null,"faq": Json | null,"id": string | null,"is_template": boolean | null,"kyc_required": boolean | null,"max_clips_per_clipper": number | null,"max_duration_sec": number | null,"min_account_age_days": number | null,"min_duration_sec": number | null,"min_followers": number | null,"min_trust_score": number | null,"min_views": number | null,"org_id": string | null,"pinned_until": string | null,"platforms": ("tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x")[] | null,"required_hashtags": (string)[] | null,"required_links": (string)[] | null,"required_mentions": (string)[] | null,"review_mode": string | null,"service_mode": string | null,"slug": string | null,"sponsored_label": boolean | null,"start_at": string | null,"status": "draft"|"in_review"|"cancelled"|"scheduled"|"rejected"|"live"|"paused"|"tracking"|"exhausted"|"settling"|"settled" | null,"submit_deadline": string | null,"title": string | null,"type": string | null,"view_window_days": number | null,"visibility": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "allow_video_reuse"?: boolean | null,"brief"?: string | null,"category_id"?: string | null,"clipper_quota"?: number | null,"content_version"?: number | null,"created_at"?: string | null,"created_by"?: string | null,"donts"?: (string)[] | null,"dos"?: (string)[] | null,"example_urls"?: (string)[] | null,"faq"?: Json | null,"id"?: string | null,"is_template"?: boolean | null,"kyc_required"?: boolean | null,"max_clips_per_clipper"?: number | null,"max_duration_sec"?: number | null,"min_account_age_days"?: number | null,"min_duration_sec"?: number | null,"min_followers"?: number | null,"min_trust_score"?: number | null,"min_views"?: number | null,"org_id"?: string | null,"pinned_until"?: string | null,"platforms"?: ("tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x")[] | null,"required_hashtags"?: (string)[] | null,"required_links"?: (string)[] | null,"required_mentions"?: (string)[] | null,"review_mode"?: string | null,"service_mode"?: string | null,"slug"?: string | null,"sponsored_label"?: boolean | null,"start_at"?: string | null,"status"?: "draft"|"in_review"|"cancelled"|"scheduled"|"rejected"|"live"|"paused"|"tracking"|"exhausted"|"settling"|"settled" | null,"submit_deadline"?: string | null,"title"?: string | null,"type"?: string | null,"view_window_days"?: number | null,"visibility"?: string | null
                         }
                        Update: {
                           "allow_video_reuse"?: boolean | null,"brief"?: string | null,"category_id"?: string | null,"clipper_quota"?: number | null,"content_version"?: number | null,"created_at"?: string | null,"created_by"?: string | null,"donts"?: (string)[] | null,"dos"?: (string)[] | null,"example_urls"?: (string)[] | null,"faq"?: Json | null,"id"?: string | null,"is_template"?: boolean | null,"kyc_required"?: boolean | null,"max_clips_per_clipper"?: number | null,"max_duration_sec"?: number | null,"min_account_age_days"?: number | null,"min_duration_sec"?: number | null,"min_followers"?: number | null,"min_trust_score"?: number | null,"min_views"?: number | null,"org_id"?: string | null,"pinned_until"?: string | null,"platforms"?: ("tiktok"|"instagram"|"youtube"|"threads"|"facebook"|"x")[] | null,"required_hashtags"?: (string)[] | null,"required_links"?: (string)[] | null,"required_mentions"?: (string)[] | null,"review_mode"?: string | null,"service_mode"?: string | null,"slug"?: string | null,"sponsored_label"?: boolean | null,"start_at"?: string | null,"status"?: "draft"|"in_review"|"cancelled"|"scheduled"|"rejected"|"live"|"paused"|"tracking"|"exhausted"|"settling"|"settled" | null,"submit_deadline"?: string | null,"title"?: string | null,"type"?: string | null,"view_window_days"?: number | null,"visibility"?: string | null
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
                },"organizations": {
                  Row: {
                    "address": string | null,"created_at": string | null,"id": string | null,"is_agency": boolean | null,"legal_name": string | null,"name": string | null,"npwp": string | null,"org_type": string | null,"status": "pending_verification"|"verified"|"suspended" | null,"updated_at": string | null,"verified_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "address"?: string | null,"created_at"?: string | null,"id"?: string | null,"is_agency"?: boolean | null,"legal_name"?: string | null,"name"?: string | null,"npwp"?: string | null,"org_type"?: string | null,"status"?: "pending_verification"|"verified"|"suspended" | null,"updated_at"?: string | null,"verified_at"?: string | null
                         }
                        Update: {
                           "address"?: string | null,"created_at"?: string | null,"id"?: string | null,"is_agency"?: boolean | null,"legal_name"?: string | null,"name"?: string | null,"npwp"?: string | null,"org_type"?: string | null,"status"?: "pending_verification"|"verified"|"suspended" | null,"updated_at"?: string | null,"verified_at"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"profiles": {
                  Row: {
                    "avatar_path": string | null,"display_name": string | null,"id": string | null,"username": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "avatar_path"?: string | null,"display_name"?: string | null,"id"?: string | null,"username"?: string | null
                         }
                        Update: {
                           "avatar_path"?: string | null,"display_name"?: string | null,"id"?: string | null,"username"?: string | null
                         }
                        Relationships: [
                    
                  ]
                }
          }
          Functions: {
            "accept_org_invite":
{ Args: { "p_token": string }; Returns: string
                           },
"bus_receive":
{ Args: { "p_events": Json,"p_source": string }; Returns: Json
                           },
"create_org":
{ Args: { "p_address"?: string,"p_is_agency"?: boolean,"p_legal_name"?: string,"p_name": string,"p_npwp"?: string,"p_org_type": string }; Returns: string
                           },
"create_org_invite":
{ Args: { "p_org": string,"p_role": string }; Returns: string
                           },
"duplicate_campaign":
{ Args: { "p_as_template"?: boolean,"p_campaign": string }; Returns: string
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
"manage_org":
{ Args: { "p_action": string,"p_org": string,"p_params"?: Json }; Returns: undefined
                           },
"manage_team":
{ Args: { "p_action": string,"p_org": string,"p_role"?: string,"p_target": string }; Returns: undefined
                           },
"save_campaign":
{ Args: { "p_campaign": Json }; Returns: Json
                           },
"update_org":
{ Args: { "p_address"?: string,"p_legal_name"?: string,"p_name": string,"p_npwp"?: string,"p_org": string }; Returns: undefined
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
