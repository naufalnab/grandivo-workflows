# Validation

Perubahan `fix/olsera-token-flow` divalidasi dengan:

- parse JSON untuk `olsera_to_postgres.json`;
- `node --check` untuk Code node validasi token, mapping produk, dan ringkasan;
- pengecekan bahwa workflow tidak menyimpan `app_id`, `secret_key`, access token, credential ID Olsera, atau instance ID.

Pengujian API nyata tetap harus dilakukan dari instance n8n Grandivo karena nilai rahasia dan akses toko tidak tersedia di repository.
