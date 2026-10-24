CREATE TABLE "market"."org_links" (
  "agency_org_id" uuid                     NOT NULL,
  "client_org_id" uuid                     NOT NULL,
  "approved_at"   timestamp with time zone,
  "revoked_at"    timestamp with time zone,
  "created_at"    timestamp with time zone NOT NULL,
  CONSTRAINT "org_links_pkey" PRIMARY KEY (agency_org_id, client_org_id)
);

ALTER TABLE "market"."org_links"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."org_members" (
  "org_id"     uuid                     NOT NULL,
  "user_id"    uuid                     NOT NULL,
  "role"       market.org_role          NOT NULL,
  "created_at" timestamp with time zone NOT NULL,
  CONSTRAINT "org_members_pkey" PRIMARY KEY (org_id, user_id)
);

ALTER TABLE "market"."org_members"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."organizations" (
  "id"          uuid                     NOT NULL,
  "name"        text                     NOT NULL,
  "is_agency"   boolean                  NOT NULL DEFAULT false,
  "verified_at" timestamp with time zone,
  "created_at"  timestamp with time zone NOT NULL,
  CONSTRAINT "organizations_pkey" PRIMARY KEY (id)
);

ALTER TABLE "market"."organizations"
  ENABLE ROW LEVEL SECURITY;

CREATE TYPE "market"."org_status" AS ENUM (
  'pending_verification',
  'verified',
  'suspended'
);

ALTER TABLE "market"."organizations"
  ADD COLUMN "status" market.org_status NOT NULL;

ALTER TABLE "market"."org_links"
  ADD CONSTRAINT "org_links_agency_org_id_fkey" FOREIGN KEY (agency_org_id) REFERENCES market.organizations(id) ON DELETE CASCADE;

ALTER TABLE "market"."org_links"
  ADD CONSTRAINT "org_links_client_org_id_fkey" FOREIGN KEY (client_org_id) REFERENCES market.organizations(id) ON DELETE CASCADE;

ALTER TABLE "market"."org_members"
  ADD CONSTRAINT "org_members_org_id_fkey" FOREIGN KEY (org_id) REFERENCES market.organizations(id) ON DELETE CASCADE;

CREATE INDEX org_links_client_idx ON market.org_links USING btree (client_org_id);

CREATE INDEX org_members_user_idx ON market.org_members USING btree (user_id);
