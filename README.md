# Slyber Turn Server

**Slyber Turn Server** is a fast, zero-configuration WebRTC STUN/TURN server.

### What is this and why do you need it?

When you build a voice or video calling app using WebRTC, browsers try to connect to each other directly (Peer-to-Peer). However, **15% to 25% of real world users** sit behind strict corporate firewalls, symmetric NAT routers, or mobile 4G/5G networks that block direct connections. Without a TURN server, calls for these users simply fail with silence or a black screen.

A **TURN server** acts as a fast media relay. When two users cannot connect directly, Slyber Turn Server forwards their encrypted audio and video packets between them with minimal latency.

**Why Slyber Turn Server instead of traditional solutions like `coturn`?**
* **Zero configuration on start:** Automatically detects its own public IP via STUN and generates a secure secret key on first install.
* **No external databases required:** Uses stateless `HMAC-SHA1` tokens (similar to JWT). You do not need Redis, PostgreSQL, or MySQL.
* **Built-in diagnostics & speed tests:** Includes `slyber_turn doctor` and `slyber_turn bench` in the same binary so you can verify your server and measure packet loss/jitter in one command.
* **Built-in security:** Automatically blocks SSRF attacks (attempts to scan your internal network or cloud metadata) and lets you limit bandwidth per call.

---

## Step 1. Installation (10 Seconds)

Run this command on your Linux server (Ubuntu, Debian, CentOS, RHEL, or Rocky Linux):

```bash
curl -fsSL https://raw.githubusercontent.com/slyber-app/slyber-turn-server/main/install.sh | sudo bash
```

If you want to specify your own secret key and domain realm right away:

```bash
curl -fsSL https://raw.githubusercontent.com/slyber-app/slyber-turn-server/main/install.sh | sudo env TURN_SECRET="my-super-secret-turn-key-12345" REALM="example.com" bash
```

**What happens when you run this command:**
1. The installer detects your CPU (`x86_64` or `arm64`), downloads the binary to `/opt/slyber_turn/slyber_turn`, and creates a shortcut in `/usr/local/bin/slyber_turn`.
2. It creates `/opt/slyber_turn/.env` with an auto generated `TURN_SECRET` and sets `PUBLIC_IP="auto"`.
3. It registers and starts the background service `slyber_turn.service` in `systemd`.
4. It runs `slyber_turn doctor` and prints your **Public IP** and your **`TURN_SECRET`** right in the terminal.

---

## Step 2. Open Firewall Ports

For WebRTC clients to reach your server, make sure these ports are open both on your server (`ufw`) and in your cloud provider's panel (**Hetzner Cloud Firewall**, **AWS Security Group**, **DigitalOcean Firewall**):

| Port | Protocol | Who needs access | Why it is needed |
| :--- | :--- | :--- | :--- |
| **`3478`** | **UDP & TCP** | Everyone (`0.0.0.0/0`) | Main port where browsers connect for STUN and TURN handshakes. |
| **`5349`** | **TCP** | Everyone (`0.0.0.0/0`) | Encrypted `turns:` connections over TLS (if SSL is enabled). |
| **`49152:65535`** | **UDP** | Everyone (`0.0.0.0/0`) | Media relay ports that carry actual voice and video packets during a call. |
| **`8080`** | **TCP** | **Private** (Your backend IP only) | Built in HTTP API for metrics, logs, and optional token fetching. |

Copy and run these commands on Ubuntu/Debian to open the required WebRTC ports:

```bash
sudo ufw allow 3478/udp comment 'STUN and TURN UDP'
sudo ufw allow 3478/tcp comment 'TURN TCP'
sudo ufw allow 5349/tcp comment 'TURNS TLS'
sudo ufw allow 49152:65535/udp comment 'TURN Media Relay Pool'
```

---

## Step 3. Connect Your Application

To start a WebRTC call through Slyber Turn Server, your application requests temporary credentials from the server's built in HTTP API:

```text
GET http://203.0.113.10:8080/api/turn-credentials?user_id=user_42&ttl=7200
```

The TURN server responds with a ready to use JSON object containing temporary `username` and `password` credentials along with all active `uris`:

```json
{
  "username": "1761845000:user_42",
  "password": "temp_token_string",
  "ttl": 7200,
  "uris": [
    "stun:203.0.113.10:3478",
    "turn:203.0.113.10:3478?transport=udp",
    "turn:203.0.113.10:3478?transport=tcp"
  ]
}
```

You can integrate this endpoint in two ways depending on your security preferences:
* **Option A (Direct from Browser):** Your frontend JavaScript calls `/api/turn-credentials` directly. You can restrict which websites are allowed to do this via `ALLOWED_ORIGINS` in `/opt/slyber_turn/.env`.
* **Option B (Via Your Backend — Recommended for Production):** You enable `REQUIRE_SECRET=true` in `/opt/slyber_turn/.env`. Your backend requests credentials from the TURN server passing the `X-Turn-Secret` header and forwards the JSON to the browser.

---

### Option A. Direct Browser Integration (Frontend JavaScript)

Replace `203.0.113.10` with your TURN server's IP address:

```javascript
async function createPeerConnection(currentUserId) {
  const TURN_API = 'http://' + '203.0.113.10:8080';

  // 1. Fetch temporary TURN credentials from Slyber Turn Server HTTP API
  const response = await fetch(
    `${TURN_API}/api/turn-credentials?user_id=${encodeURIComponent(currentUserId)}`
  );
  if (!response.ok) {
    throw new Error(`Failed to fetch TURN credentials: HTTP ${response.status}`);
  }
  const turn = await response.json();

  // 2. Pass the returned URIs and credentials into RTCPeerConnection
  const pc = new RTCPeerConnection({
    iceServers: [
      {
        urls: turn.uris,
        username: turn.username,
        credential: turn.password
      }
    ],
    // TIP: Uncomment the line below during testing to force the call through the TURN relay
    // (disables direct Peer-to-Peer connection):
    // iceTransportPolicy: 'relay'
  });

  return pc;
}
```

---

### Option B. Fetching Credentials from Your Backend (`X-Turn-Secret`)

If you want only your backend to be able to request TURN credentials, set `REQUIRE_SECRET=true` in `/opt/slyber_turn/.env` and pass the `X-Turn-Secret` header from your server.

#### 1. Quick Terminal Test (cURL)
```bash
TURN_HOST="203.0.113.10:8080"
curl -i -H "X-Turn-Secret: YOUR_TURN_SECRET" \
  "http://${TURN_HOST}/api/turn-credentials?user_id=user_42&ttl=3600"
```

#### 2. Node.js
```javascript
export async function fetchTurnCredentials(userId, turnHost = '203.0.113.10:8080') {
  const url = `http://${turnHost}/api/turn-credentials?user_id=${encodeURIComponent(userId)}&ttl=7200`;

  const response = await fetch(url, {
    method: 'GET',
    headers: {
      'X-Turn-Secret': process.env.TURN_SECRET
    }
  });

  if (!response.ok) {
    throw new Error(`TURN API returned HTTP ${response.status}`);
  }

  return await response.json();
}
```

#### 3. Go
```go
package turnapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"
)

type IceConfig struct {
	Username string   `json:"username"`
	Password string   `json:"password"`
	TTL      int64    `json:"ttl"`
	URIs     []string `json:"uris"`
}

func FetchTurnCredentials(ctx context.Context, turnAPIURL, secret, userID string) (*IceConfig, error) {
	endpoint := fmt.Sprintf("%s/api/turn-credentials?user_id=%s&ttl=7200",
		turnAPIURL, url.QueryEscape(userID))

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Turn-Secret", secret)

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected HTTP status: %d", resp.StatusCode)
	}

	var cfg IceConfig
	if err := json.NewDecoder(resp.Body).Decode(&cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}
```

#### 4. Python
```python
import urllib.parse
import urllib.request
import json

def fetch_turn_credentials(user_id: str, turn_secret: str, turn_host: str = "203.0.113.10:8080") -> dict:
    query = urllib.parse.urlencode({"user_id": user_id, "ttl": 7200})
    url = f"http://{turn_host}/api/turn-credentials?{query}"

    req = urllib.request.Request(url, headers={"X-Turn-Secret": turn_secret})
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.loads(response.read().decode("utf-8"))
```

#### 5. PHP
```php
function fetchTurnCredentials(string $userId, string $turnSecret, string $turnHost = '203.0.113.10:8080'): array {
    $url = "http://{$turnHost}/api/turn-credentials?user_id=" . urlencode($userId) . '&ttl=7200';

    $context = stream_context_create([
        'http' => [
            'method'  => 'GET',
            'header'  => "X-Turn-Secret: {$turnSecret}\r\n",
            'timeout' => 5,
        ],
    ]);

    $json = file_get_contents($url, false, $context);
    if ($json === false) {
        throw new RuntimeException('Failed to fetch TURN credentials');
    }

    return json_decode($json, true);
}
```

---

## Step 4. Verify & Benchmark Your Server

Slyber Turn Server includes two built in CLI tools so you never have to guess if your server is working properly.

### 1. Run Self Diagnostics (`doctor`)

Run this command on your server to check your config, verify that your external IP matches STUN, and perform a live test allocation:

```bash
sudo slyber_turn doctor
```

Expected output:
```text
[INFO] Running slyber_turn doctor diagnostics...
--------------------------------------------------
[OK] Configuration valid (realm: turn.local, relay port pool: 49152-65535, capacity: 16384 sessions)
[OK] HTTP API protection active (origins: 1, require_secret: false)
[OK] STUN check passed in 11ms: PUBLIC_IP (203.0.113.10) matches external IP
[INFO] UDP port 3478 is already in use - switching to running server verification (Live Probe)...
[OK] HTTP API (:8080/healthz) responded normally (200 OK)
[OK] TURN Allocate succeeded in 1.42ms (allocated relay address: 203.0.113.10:52109)
--------------------------------------------------
[OK] Diagnostics completed successfully. Server is ready.
```

### 2. Run a Load & Quality Benchmark (`bench`)

Want to know how many Mbps your server can handle, or test packet loss and jitter from your laptop to a remote VPS?

**Run locally on the server (tests CPU and OS socket performance):**
```bash
sudo slyber_turn bench -clients 20 -duration 5s
```

**Run from your laptop to a remote server over the internet (tests real network quality):**
```bash
slyber_turn bench -target 203.0.113.10:3478 -secret "YOUR_TURN_SECRET" -realm "turn.local" -clients 20 -duration 5s
```

Sample output:
```text
[INFO] Starting Slyber Turn benchmark against 203.0.113.10:3478 (mode: live-local, clients: 20, duration: 5s, payload: 1200 B)...
----------------------------------------------------------------------
  Allocation Setup : 20/20 succeeded | avg: 11.11 ms | p95: 17.68 ms | max: 19.96 ms
  Relay Throughput : 19.19 Mbps (1999 packets/sec, 11.44 MB relayed)
  Packet Delivery  : 5000 sent | 5000 recv | 0.00% loss (0 dropped)
  Relay Latency    : ~3.87 ms one-way (4-leg loop RTT avg: 7.74 ms | p50: 7.68 ms | p95: 10.35 ms)
  Media Jitter     : 1.30 ms (RFC 3550)
  Quality Verdict  : [OK] EXCELLENT (Ready for low-latency HD Voice & Video)
----------------------------------------------------------------------
```
*(Add the `-json` flag if you want the benchmark output formatted as JSON for automated scripts).*

---

## Step 5. Configuration Reference (`/opt/slyber_turn/.env`)

All settings are stored in `/opt/slyber_turn/.env`. After editing this file, restart the service:

```bash
sudo nano /opt/slyber_turn/.env
sudo systemctl restart slyber_turn
```

| `.env` Variable | CLI Flag | Default | What it does |
| :--- | :--- | :--- | :--- |
| `TURN_SECRET` | `-secret` | *(Auto-generated)* | Shared secret key used to sign temporary credentials (min **16 chars**). |
| `PUBLIC_IP` | `-public-ip` | `auto` | Your server's public IPv4. Leave as `auto` to detect it automatically via STUN. |
| `REALM` | `-realm` | `turn.local` | TURN domain realm identifier (e.g., `example.com`). |
| `UDP_PORT` | `-udp-port` | `3478` | Main UDP port for STUN and TURN. |
| `TCP_PORT` | `-tcp-port` | `3478` | Main TCP port for TURN (fallback when UDP is blocked on client network). |
| `TLS_PORT` | `-tls-port` | `5349` | Port for encrypted `turns:` connections over TLS. |
| `MAX_KBPS_PER_SESSION` | `-max-kbps` | `0` | Speed limit per call in Kbps (`0` = unlimited, `256` = voice only, `2000` = 2 Mbps HD video). |
| `RELAY_MIN_PORT` | — | `49152` | Start of UDP port range for media relay. |
| `RELAY_MAX_PORT` | — | `65535` | End of UDP port range for media relay (16,384 ports total). |
| `CREDENTIAL_TTL_SEC` | — | `7200` | How long temporary credentials stay valid in seconds (7200 = 2 hours). |
| `HTTP_ENABLED` | `-http-enabled` | `true` | Enables the built-in HTTP API server on `HTTP_PORT`. |
| `HTTP_PORT` | `-http-port` | `:8080` | Port for HTTP API (set to `127.0.0.1:8080` to make it local-only). |
| `HTTP_TLS` | `-http-tls` | `false` | Enables `HTTPS` on the HTTP API port (requires TLS certificates). |
| `REQUIRE_SECRET` | `-require-secret` | `false` | If `true`, `/api/turn-credentials` requires the `X-Turn-Secret` header on every request. |
| `ALLOWED_ORIGINS` | — | `*` | Comma-separated domains allowed via browser CORS (e.g., `https://example.com`). |
| `ALLOWED_IPS` | — | `""` | Optional comma-separated IP/CIDR allowlist for HTTP API access. |
| `TURN_ALLOWED_PEER_IPS` | — | `""` | Optional IP/CIDR allowlist for clients connecting to TURN ports `3478`/`5349`. |
| `TLS_CERT_FILE` | — | `""` | Path to SSL certificate (`fullchain.pem`). Reloaded automatically when renewed. |
| `TLS_KEY_FILE` | — | `""` | Path to SSL private key (`privkey.pem`). |
| `TLS_SELF_SIGNED` | — | `false` | Set to `true` to generate an in-memory self-signed TLS certificate automatically. |
| `TURN_THREADS` | — | `NumCPU()` | Number of parallel `SO_REUSEPORT` UDP listeners on Linux. |
| `DATA_DIR` | — | `/opt/slyber_turn` | Folder where `stats.json` and `events.jsonl` are saved. |
| `LOG_FORMAT` | — | `json` | Log output format (`text` for human reading, `json` for production logs). |

---

## Step 6. Monitoring, Live Sessions & Logs

### Useful `systemd` Commands
```bash
# Check service status
sudo systemctl status slyber_turn

# Watch live server logs
sudo journalctl -u slyber_turn -f

# Restart server after changing .env
sudo systemctl restart slyber_turn
```

### Built in HTTP Monitoring API
You can query live server stats from localhost (`127.0.0.1`) or remotely by passing the `X-Turn-Secret` header:

* **`GET /healthz`** — Public health check (`{"status":"ok"}`).
* **`GET /metrics`** — Prometheus metrics (`turn_active_allocations`, `turn_relayed_bytes_total`, `turn_auth_requests_total`, `turn_ssrf_blocked_total`).
* **`GET /api/node-stats`** — Detailed JSON dashboard data: active calls right now (`active_sessions_list` with user IDs, client IPs, duration, and bytes), 24 hour traffic history (`hourly_24h`), and blocked IPs (`top_offenders`).
* **`GET /events`** — Last 2,000 events (`CREDS_ISSUED`, `AUTH_OK`, `SESSION_CLOSED`, `AUTH_FAIL`, `SSRF_BLOCK`).

Example request on the server:
```bash
curl -s http://127.0.0.1:8080/api/node-stats | jq 
```

---

## Step 7. Updating & Uninstalling

**Update to the latest version** (your `/opt/slyber_turn/.env` and saved statistics are kept intact):
```bash
curl -fsSL https://raw.githubusercontent.com/slyber-app/slyber-turn-server/main/install.sh | sudo bash
```

**Uninstall the service:**
```bash
curl -fsSL https://raw.githubusercontent.com/slyber-app/slyber-turn-server/main/uninstall.sh | sudo bash
```

---

## Under the Hood (For Senior Engineers & Architects)

* **Multi-Queue `SO_REUSEPORT` UDP Scaling:** On Linux, the server opens independent UDP sockets per CPU core with `SO_REUSEPORT` so the kernel distributes incoming packet streams across cores without lock contention, and cascades socket buffers (`SO_RCVBUF` / `SO_SNDBUF`) up to **4 MB**.
* **Lock-Free Media Hot Path:** RTP packet forwarding updates per-allocation atomic counters (`0 allocs/op`) and flushes byte counters to global telemetry in **64 KB** batches.
* **Atomic Token-Bucket Bandwidth Shaper:** Per-session rate limiting (`MAX_KBPS_PER_SESSION`) runs on lock-free `CompareAndSwap` operations with a 10 ms refill interval and a 64 KB minimum burst for video keyframes.
* **Zombie Session Detection & ICE Grouping:** Standard RFC 5766 UDP allocations time out after 10 minutes. Slyber Turn Server tracks `lastActiveNano` per allocation and closes idle sessions after **30 seconds** of silence with accurate call duration logging, while grouping parallel standby ICE sockets from the same user.
* **SSRF Protection with TURN Hairpinning:** Blocks loopback (`127.0.0.1`, `::1`), `0.0.0.0/8`, RFC 1918 private networks, CGNAT (`100.64.0.0/10`), cloud metadata (`169.254.169.254`, `fd00:ec2::254`), and host-internal interfaces, while explicitly allowing `PUBLIC_IP` so two peers on the same TURN server can communicate via hairpinning.
* **Atomic Write-Behind Persistence:** Flushes 24h counters (`stats.json`) and a 2,000-entry ring buffer (`events.jsonl`) to disk every 10 seconds via temp-file write + atomic `rename()`.