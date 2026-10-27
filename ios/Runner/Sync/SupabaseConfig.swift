import Foundation

/// Supabase project settings for image storage (Project settings > API). Keep in sync with SupabaseConfig.kt.
/// The anon key is a public client key, protected by the Storage policies in docs/supabase_setup.sql.
/// Until these are filled in, posts with images stay queued on the device (text-only posts still sync).
enum SupabaseConfig {
    static let url = "YOUR_SUPABASE_URL"          // e.g. https://abcdxyz.supabase.co
    static let anonKey = "YOUR_SUPABASE_ANON_KEY"
    static let bucket = "post-images"             // public bucket, see docs/supabase_setup.sql
}
