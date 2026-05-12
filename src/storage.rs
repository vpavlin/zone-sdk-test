use std::path::Path;
use std::time::Duration;

type Error = Box<dyn std::error::Error + Send + Sync>;

#[derive(Clone)]
pub struct StorageClient {
    base: String,
    prefix: String,
    client: reqwest::Client,
}

impl StorageClient {
    pub fn new(base_url: &str, prefix: &str) -> Result<Self, Error> {
        let base = base_url.trim_end_matches('/').to_string();
        let prefix = format!("/{}", prefix.trim_matches('/'));
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(120))
            .build()?;
        Ok(Self { base, prefix, client })
    }

    pub async fn upload_file(&self, path: &str) -> Result<UploadResult, Error> {
        let path = Path::new(path);
        let bytes = tokio::fs::read(path).await
            .map_err(|e| format!("read file: {e}"))?;
        let size = bytes.len() as u64;
        let mime = mime_from_path(path);
        let filename = path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();

        let url = format!("{}{}/data", self.base, self.prefix);
        let resp = self
            .client
            .post(&url)
            .header("Content-Type", mime)
            .header("Codex-Filename", &filename)
            .body(bytes)
            .send()
            .await?
            .error_for_status()?;

        let cid = resp.text().await
            .map_err(|e| format!("read upload response: {e}"))?;
        let cid = cid.trim().to_string();
        Ok(UploadResult {
            cid,
            mime: mime.to_string(),
            filename,
            size,
        })
    }
}

pub struct UploadResult {
    pub cid: String,
    pub mime: String,
    pub filename: String,
    pub size: u64,
}

fn mime_from_path(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_lowercase())
        .as_deref()
    {
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("mp4") => "video/mp4",
        Some("webm") => "video/webm",
        Some("txt") => "text/plain",
        Some("json") => "application/json",
        _ => "application/octet-stream",
    }
}
