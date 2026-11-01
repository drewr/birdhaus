-- Page copy that admins edit at /admin/site, as Markdown or HTML. A section
-- with no row shows the text built into server/copy.js.
create table site_copy (
  key text primary key,
  body text not null,
  updated_at timestamptz not null default now(),
  updated_by text
);
