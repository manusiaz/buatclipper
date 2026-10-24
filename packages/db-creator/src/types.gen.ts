
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "api": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            "claims": {
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
                }
          }
          Functions: {
            "bus_receive":
{ Args: { "p_events": Json,"p_source": string }; Returns: Json
                           },
"ensure_profile":
{ Args: { "p_avatar_path"?: string,"p_display_name": string,"p_referral_code"?: string,"p_username": string }; Returns: {
              "created": boolean,"display_name": string,"id": string,"username": string
            }[]
                           },
"health":
{ Args: Record<PropertyKey, never>; Returns: Json
                           },
"missing_brief_tags":
{ Args: { "p_campaign": string,"p_caption": string }; Returns: (string)[]
                           },
"store_social_token":
{ Args: { "p_account_id": string,"p_token": string }; Returns: string
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
