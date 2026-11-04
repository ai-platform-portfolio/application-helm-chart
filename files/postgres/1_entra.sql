-- The role is AtlasSchema-owned; this migration maps it to its ASO identity.
DO $$ BEGIN
  EXECUTE format('SECURITY LABEL FOR pgaadauth ON ROLE %I IS %L',
    '{{ .runtime }}', 'aadauth,oid={{ .principal_id }},type=service');
END $$;
