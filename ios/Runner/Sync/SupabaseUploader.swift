import Foundation

/// Uploads an image to Supabase Storage over its REST API (no SDK) and returns the public URL.
enum SupabaseUploader {
    static var isConfigured: Bool {
        !SupabaseConfig.url.contains("YOUR_") && !SupabaseConfig.anonKey.contains("YOUR_")
    }

    /// Blocking; call from the flush queue. Returns the public URL on success, nil on any failure.
    static func upload(fileURL: URL, objectPath: String) -> String? {
        let base = SupabaseConfig.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/storage/v1/object/\(SupabaseConfig.bucket)/\(objectPath)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: Config.uploadTimeout)
        req.httpMethod = "POST"
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert") // retries overwrite the same object instead of 409
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.uploadTask(with: req, fromFile: fileURL) { data, resp, err in
            if err == nil, let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) {
                ok = true
            } else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                NSLog("[Sync] supabase upload failed: %@ %@", err?.localizedDescription ?? "", body)
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + Config.uploadTimeout + 5) == .timedOut { task.cancel(); return nil }
        return ok ? "\(base)/storage/v1/object/public/\(SupabaseConfig.bucket)/\(objectPath)" : nil
    }
}
