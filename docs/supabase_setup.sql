-- Run once in Supabase Dashboard > SQL Editor.
-- Creates a public image bucket and lets the app (anon key) upload/overwrite objects in it.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('post-images', 'post-images', true, 10485760, array['image/jpeg'])
on conflict (id) do update
  set public = true, file_size_limit = 10485760, allowed_mime_types = array['image/jpeg'];

-- The app uploads with x-upsert (retries overwrite the same object), which needs insert + update + select.
create policy "post-images insert" on storage.objects
  for insert to anon with check (bucket_id = 'post-images');
create policy "post-images update" on storage.objects
  for update to anon using (bucket_id = 'post-images') with check (bucket_id = 'post-images');
create policy "post-images select" on storage.objects
  for select to anon using (bucket_id = 'post-images');
-- No delete policy: the app can never delete images.
