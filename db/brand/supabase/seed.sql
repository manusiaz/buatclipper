-- Issuer identity per environment (produksi: dari discovery identity).
insert into ops.settings (key, value) values ('auth.identity_issuer', '"http://127.0.0.1:54321/auth/v1"')
on conflict (key) do update set value = excluded.value;
