package com.demo.background_sync_demo

/**
 * Supabase project settings for image storage (Project settings > API). The anon key is a public client key,
 * protected by the Storage policies in docs/supabase_setup.sql, not by secrecy.
 * Until these are filled in, posts with images stay queued on the device (text-only posts still sync).
 */
object SupabaseConfig {
    const val URL = "YOUR_SUPABASE_URL"          // e.g. https://abcdxyz.supabase.co
    const val ANON_KEY = "YOUR_SUPABASE_ANON_KEY"
    const val BUCKET = "post-images"             // public bucket, see docs/supabase_setup.sql
}
