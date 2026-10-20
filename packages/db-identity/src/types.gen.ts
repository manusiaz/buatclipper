
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
                },"legal_versions": {
                  Row: {
                    "kind": "tos_clipper"|"tos_brand"|"privacy"|"age_18_plus"|"kyc"|"share_with_brand" | null,"published_at": string | null,"url": string | null,"version": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "kind"?: "tos_clipper"|"tos_brand"|"privacy"|"age_18_plus"|"kyc"|"share_with_brand" | null,"published_at"?: string | null,"url"?: string | null,"version"?: string | null
                         }
                        Update: {
                           "kind"?: "tos_clipper"|"tos_brand"|"privacy"|"age_18_plus"|"kyc"|"share_with_brand" | null,"published_at"?: string | null,"url"?: string | null,"version"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"my_consents": {
                  Row: {
                    "granted_at": string | null,"kind": "tos_clipper"|"tos_brand"|"privacy"|"age_18_plus"|"kyc"|"share_with_brand" | null,"revoked_at": string | null,"version": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "granted_at"?: string | null,"kind"?: "tos_clipper"|"tos_brand"|"privacy"|"age_18_plus"|"kyc"|"share_with_brand" | null,"revoked_at"?: string | null,"version"?: string | null
                         }
                        Update: {
                           "granted_at"?: string | null,"kind"?: "tos_clipper"|"tos_brand"|"privacy"|"age_18_plus"|"kyc"|"share_with_brand" | null,"revoked_at"?: string | null,"version"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"my_kyc": {
                  Row: {
                    "decided_at": string | null,"legal_name": string | null,"nik_last4": string | null,"reject_reason": string | null,"status": "pending"|"approved"|"rejected" | null,"submitted_at": string | null,"user_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "decided_at"?: string | null,"legal_name"?: string | null,"nik_last4"?: string | null,"reject_reason"?: string | null,"status"?: "pending"|"approved"|"rejected" | null,"submitted_at"?: string | null,"user_id"?: string | null
                         }
                        Update: {
                           "decided_at"?: string | null,"legal_name"?: string | null,"nik_last4"?: string | null,"reject_reason"?: string | null,"status"?: "pending"|"approved"|"rejected" | null,"submitted_at"?: string | null,"user_id"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"my_recipients": {
                  Row: {
                    "id": string | null,"reward_type_id": string | null,"updated_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "id"?: string | null,"reward_type_id"?: string | null,"updated_at"?: string | null
                         }
                        Update: {
                           "id"?: string | null,"reward_type_id"?: string | null,"updated_at"?: string | null
                         }
                        Relationships: [
                    
                  ]
                },"push_subscriptions": {
                  Row: {
                    "created_at": string | null,"endpoint": string | null,"id": string | null,"last_used_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "created_at"?: string | null,"endpoint"?: string | null,"id"?: string | null,"last_used_at"?: string | null
                         }
                        Update: {
                           "created_at"?: string | null,"endpoint"?: string | null,"id"?: string | null,"last_used_at"?: string | null
                         }
                        Relationships: [
                    
                  ]
                }
          }
          Functions: {
            "admin_kyc_decision":
{ Args: { "p_decision": string,"p_reason"?: string,"p_user_id": string }; Returns: undefined
                           },
"admin_kyc_queue":
{ Args: { "p_limit"?: number,"p_status"?: string }; Returns: {
              "decided_at": string,"reject_reason": string,"status": string,"submitted_at": string,"user_id": string
            }[]
                           },
"admin_list_roles":
{ Args: Record<PropertyKey, never>; Returns: {
              "email": string,"granted_at": string,"roles": (string)[],"user_id": string
            }[]
                           },
"admin_read":
{ Args: { "p_user_id": string }; Returns: {
              "doc_ref": string,"legal_name": string,"nik_last4": string,"payout_methods": Json,"status": "pending"|"approved"|"rejected","submitted_at": string,"user_id": string
            }[]
                           },
"admin_set_role":
{ Args: { "p_grant": boolean,"p_role": string,"p_user_id": string }; Returns: undefined
                           },
"my_payout_methods":
{ Args: Record<PropertyKey, never>; Returns: {
              "account_last4": string,"account_name": string,"bank_code": string,"id": string,"kind": string,"verified_at": string
            }[]
                           },
"record_consent":
{ Args: { "p_granted"?: boolean,"p_kind": string,"p_version"?: string }; Returns: undefined
                           },
"save_push_subscription":
{ Args: { "p_auth": string,"p_endpoint": string,"p_p256dh": string }; Returns: string
                           },
"shared_device_groups":
{ Args: { "p_min_accounts"?: number,"p_since"?: string }; Returns: {
              "ip": unknown,"user_agent": string,"user_ids": (string)[]
            }[]
                           },
"store_kyc":
{ Args: { "p_doc_ref": string,"p_key_version": number,"p_legal_name": string,"p_nik_enc": string,"p_nik_hash": string,"p_nik_last4": string,"p_user_id": string }; Returns: undefined
                           },
"store_payout_method":
{ Args: { "p_account_name": string,"p_account_no_enc": string,"p_account_no_hash": string,"p_bank_code": string,"p_key_version": number,"p_kind": string,"p_last4": string,"p_user_id": string }; Returns: string
                           },
"store_recipient":
{ Args: { "p_data_enc": string,"p_key_version": number,"p_reward_type_id": string,"p_user_id": string }; Returns: string
                           },
"svc_admin_ids":
{ Args: { "p_roles": (string)[] }; Returns: (string)[]
                           },
"svc_audit":
{ Args: { "p_action": string,"p_actor": string,"p_after"?: Json,"p_target": string }; Returns: undefined
                           },
"svc_check_ids":
{ Args: { "p_method_ids": (string)[],"p_recipient_refs": (string)[],"p_user_ids": (string)[] }; Returns: Json
                           },
"svc_close_member":
{ Args: { "p_blocked": boolean,"p_retain_until": string,"p_user": string }; Returns: Json
                           },
"svc_delete_push":
{ Args: { "p_endpoint": string }; Returns: undefined
                           },
"svc_has_consent":
{ Args: { "p_kind": string,"p_user": string }; Returns: boolean
                           },
"svc_hash_holder":
{ Args: { "p_account_hash": string,"p_bank_code": string,"p_nik_hash": string }; Returns: {
              "tombstone": boolean,"user_id": string
            }[]
                           },
"svc_kyc":
{ Args: { "p_user_ids": (string)[] }; Returns: {
              "closed": boolean,"enc_key_version": number,"legal_name": string,"nik_enc": string,"status": "pending"|"approved"|"rejected","user_id": string
            }[]
                           },
"svc_my_data":
{ Args: { "p_user": string }; Returns: Json
                           },
"svc_payout_methods":
{ Args: { "p_ids": (string)[] }; Returns: {
              "account_last4": string,"account_name": string,"account_no_enc": string,"bank_code": string,"blocked": boolean,"disabled_at": string,"enc_key_version": number,"id": string,"kind": string,"user_id": string
            }[]
                           },
"svc_platform_roles":
{ Args: { "p_user": string }; Returns: (string)[]
                           },
"svc_push_subscriptions":
{ Args: { "p_user": string }; Returns: {
              "auth_secret": string,"endpoint": string,"p256dh": string
            }[]
                           },
"svc_recipients":
{ Args: { "p_ids": (string)[] }; Returns: {
              "data_enc": string,"enc_key_version": number,"id": string,"reward_type_id": string,"user_id": string
            }[]
                           },
"svc_touch_push":
{ Args: { "p_endpoint": string }; Returns: undefined
                           },
"svc_user_payout_methods":
{ Args: { "p_user": string }; Returns: {
              "account_last4": string,"account_name": string,"account_no_enc": string,"bank_code": string,"blocked": boolean,"disabled_at": string,"enc_key_version": number,"id": string,"kind": string,"user_id": string
            }[]
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
