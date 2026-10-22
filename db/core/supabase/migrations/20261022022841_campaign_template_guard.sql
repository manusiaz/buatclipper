SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION market.template_stays_draft()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if new.is_template and new.status <> 'draft' then
    raise exception 'invalid:template' using errcode = '23514', detail = 'template tidak bisa diajukan; duplikat dulu';
  end if;
  return new;
end $function$;

CREATE TRIGGER campaigns_template_stays_draft
  BEFORE INSERT OR UPDATE OF status ON market.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION market.template_stays_draft();

REVOKE ALL ON FUNCTION "market"."template_stays_draft"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."template_stays_draft"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."template_stays_draft"() TO "postgres";
