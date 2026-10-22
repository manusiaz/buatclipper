
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "api": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            "org_invites": {
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
"invite_preview":
{ Args: { "p_token": string }; Returns: {
              "expired": boolean,"is_agency": boolean,"org_name": string,"role": string,"used": boolean
            }[]
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
